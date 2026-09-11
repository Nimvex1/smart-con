// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {DAOGovernanceToken} from "../contracts/DAOGovernanceToken.sol";
import {EnterpriseDAO} from "../contracts/EnterpriseDAO.sol";
import {DAOTreasuryExecutionEngine} from "../contracts/DAOTreasuryExecutionEngine.sol";

/// @title Deploy
/// @notice Bootstrap deployment for the Enterprise DAO ecosystem following the sequence
///         documented in `contracts/DAODeploymentNotes.sol`.
///
///         Trust topology after this script:
///         Token holders -> Governor -> TimelockController -> TreasuryExecutionEngine
///
///         Required environment variables:
///         - INITIAL_RECIPIENT   address receiving the full initial token supply (multisig)
///         - GUARDIAN_ADDRESS   emergency guardian (recommend an audited multisig)
///
///         Optional environment variables (defaults shown):
///         - TOKEN_NAME            "Enterprise DAO Token"
///         - TOKEN_SYMBOL          "EDAO"
///         - INITIAL_SUPPLY        100_000_000e18
///         - TIMELOCK_MIN_DELAY    2 days
///         - GOV_VOTING_DELAY      7200    (blocks, ~1 day at 12s blocks)
///         - GOV_VOTING_PERIOD     30240   (blocks, ~3.5 days)
///         - GOV_QUORUM_MIN_BPS    400     (4%)
///         - GOV_QUORUM_MAX_BPS    1000    (10%)
///         - GOV_THRESHOLD         250_000e18 (0.25% of default supply)
///
///         FINAL MANUAL STEP (not automated on purpose): after verifying all roles, the
///         deployer must renounce its temporary DEFAULT_ADMIN_ROLE on the timelock, e.g.
///         `cast send <timelock> "renounceRole(bytes32,address)" <DEFAULT_ADMIN_ROLE>
///         <deployer>`. Renouncing is deliberately left manual so a misconfiguration can
///         still be corrected before governance becomes self-sovereign.
contract Deploy is Script {
    struct DeployParams {
        string tokenName;
        string tokenSymbol;
        address initialRecipient;
        uint256 initialSupply;
        address guardian;
        uint256 timelockMinDelay;
        uint48 votingDelay;
        uint32 votingPeriod;
        uint256 proposalThreshold;
        uint256 quorumMinBps;
        uint256 quorumMaxBps;
    }

    function run() external {
        DeployParams memory params = _readParams();

        vm.startBroadcast();

        // ------------------------------------------------------------------
        // 1. Governance token (fixed supply, minted once)
        // ------------------------------------------------------------------
        DAOGovernanceToken token =
            new DAOGovernanceToken(params.tokenName, params.tokenSymbol, params.initialRecipient, params.initialSupply);
        console2.log("DAOGovernanceToken:", address(token));

        // ------------------------------------------------------------------
        // 2. Timelock: open execution, deployer as temporary admin
        // ------------------------------------------------------------------
        TimelockController timelock = _deployTimelock(params.timelockMinDelay);

        // ------------------------------------------------------------------
        // 3. Treasury: timelock becomes GOVERNANCE_ROLE, guardian gets GUARDIAN_ROLE
        // ------------------------------------------------------------------
        DAOTreasuryExecutionEngine treasury = new DAOTreasuryExecutionEngine(address(timelock), params.guardian);
        console2.log("DAOTreasuryExecutionEngine:", address(treasury));

        // ------------------------------------------------------------------
        // 4. Governor
        // ------------------------------------------------------------------
        EnterpriseDAO governor = _deployGovernor(token, timelock, params);
        console2.log("EnterpriseDAO:", address(governor));

        // ------------------------------------------------------------------
        // 5. Wire the governor into the timelock
        // ------------------------------------------------------------------
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));
        // EXECUTOR_ROLE is already open via address(0).

        vm.stopBroadcast();

        // ------------------------------------------------------------------
        // Post-deployment report
        // ------------------------------------------------------------------
        console2.log("--------------------------------------------------------");
        console2.log("Bootstrap complete. Verify, then renounce the deployer");
        console2.log("admin role on the timelock:");
        console2.log("  cast send", address(timelock));
        console2.log("    \"renounceRole(bytes32,address)\"");
        console2.log("    <DEFAULT_ADMIN_ROLE> <deployer>");
        console2.log("--------------------------------------------------------");
        console2.log("Trust topology:");
        console2.log("  token holders -> governor -> timelock -> treasury");
    }

    function _readParams() internal view returns (DeployParams memory params) {
        params.tokenName = vm.envOr("TOKEN_NAME", string("Enterprise DAO Token"));
        params.tokenSymbol = vm.envOr("TOKEN_SYMBOL", string("EDAO"));
        params.initialRecipient = vm.envAddress("INITIAL_RECIPIENT");
        params.initialSupply = vm.envOr("INITIAL_SUPPLY", uint256(100_000_000e18));
        params.guardian = vm.envAddress("GUARDIAN_ADDRESS");
        params.timelockMinDelay = vm.envOr("TIMELOCK_MIN_DELAY", uint256(2 days));
        params.votingDelay = uint48(vm.envOr("GOV_VOTING_DELAY", uint256(7_200)));
        params.votingPeriod = uint32(vm.envOr("GOV_VOTING_PERIOD", uint256(30_240)));
        params.proposalThreshold = vm.envOr("GOV_THRESHOLD", uint256(250_000e18));
        params.quorumMinBps = vm.envOr("GOV_QUORUM_MIN_BPS", uint256(400));
        params.quorumMaxBps = vm.envOr("GOV_QUORUM_MAX_BPS", uint256(1000));
    }

    function _deployTimelock(uint256 minDelay) internal returns (TimelockController timelock) {
        address[] memory noProposers = new address[](0);
        address[] memory openExecutors = new address[](1);
        openExecutors[0] = address(0); // EXECUTOR_ROLE open to anyone
        timelock = new TimelockController(minDelay, noProposers, openExecutors, msg.sender);
        console2.log("TimelockController:", address(timelock));
    }

    function _deployGovernor(DAOGovernanceToken token, TimelockController timelock, DeployParams memory params)
        internal
        returns (EnterpriseDAO governor)
    {
        // Supply thresholds for the linear quorum ramp: 25% .. 90% of initial supply.
        // Threshold bounds: 0.1x .. 4x the initial threshold.
        EnterpriseDAO.GovernorConfig memory config = EnterpriseDAO.GovernorConfig({
            name: "Enterprise DAO",
            token: IVotes(address(token)),
            timelock: timelock,
            votingDelayBlocks: params.votingDelay,
            votingPeriodBlocks: params.votingPeriod,
            proposalThreshold: params.proposalThreshold,
            quorumMinBps: params.quorumMinBps,
            quorumMaxBps: params.quorumMaxBps,
            quorumLowSupplyThreshold: params.initialSupply / 4,
            quorumHighSupplyThreshold: (params.initialSupply * 9) / 10,
            minProposalThreshold: params.proposalThreshold / 10,
            maxProposalThreshold: params.proposalThreshold * 4
        });
        governor = new EnterpriseDAO(config);
    }
}
