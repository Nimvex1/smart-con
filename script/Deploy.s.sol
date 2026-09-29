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
///         - RISK_LIMITER_ADDRESS risk limiter (recommend a security council DISTINCT
///                                from the governor and the guardian)
///
///         Optional environment variables (defaults shown):
///         - TOKEN_NAME            "Enterprise DAO Token"
///         - TOKEN_SYMBOL          "EDAO"
///         - INITIAL_SUPPLY        100_000_000e18
///         - TIMELOCK_MIN_DELAY    2 days
///         - TREASURY_MIN_TIER_DELAY 1 days (immutable floor on every tier delay)
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
        address riskLimiter;
        uint48 minTierDelay;
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
        DAOTreasuryExecutionEngine treasury =
            new DAOTreasuryExecutionEngine(address(timelock), params.guardian, params.riskLimiter, params.minTierDelay);
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
        // Post-deployment assertions: the deployment FAILS LOUDLY if any
        // wiring assumption is broken, rather than shipping a misconfigured DAO.
        // ------------------------------------------------------------------
        _assertWiring(token, timelock, treasury, governor, params);
    }

    function _assertWiring(
        DAOGovernanceToken token,
        TimelockController timelock,
        DAOTreasuryExecutionEngine treasury,
        EnterpriseDAO governor,
        DeployParams memory params
    ) internal view {
        // --- Timelock <-> Governor wiring -------------------------------------
        bytes32 proposerRole = timelock.PROPOSER_ROLE();
        bytes32 cancellerRole = timelock.CANCELLER_ROLE();
        bytes32 executorRole = timelock.EXECUTOR_ROLE();
        require(timelock.hasRole(proposerRole, address(governor)), "governor missing PROPOSER_ROLE");
        require(timelock.hasRole(cancellerRole, address(governor)), "governor missing CANCELLER_ROLE");
        require(timelock.hasRole(executorRole, address(0)), "executor role not open");
        require(timelock.getMinDelay() == params.timelockMinDelay, "timelock delay mismatch");

        // --- Treasury <-> Timelock/Guardian ----------------------------------
        require(treasury.hasRole(treasury.GOVERNANCE_ROLE(), address(timelock)), "timelock not treasury governance");
        require(treasury.hasRole(treasury.GUARDIAN_ROLE(), params.guardian), "guardian not set on treasury");
        require(treasury.hasRole(treasury.RISK_LIMITER_ROLE(), params.riskLimiter), "risk limiter not set on treasury");
        // The limiter is the whole point of the risk-limit design. If one entity can
        // both schedule packages and loosen their limits, a single compromise is enough
        // and the delay ladder is decorative again.
        require(
            !treasury.hasRole(treasury.RISK_LIMITER_ROLE(), address(timelock)),
            "timelock must NOT hold the risk limiter role"
        );
        require(
            !treasury.hasRole(treasury.GOVERNANCE_ROLE(), params.riskLimiter),
            "risk limiter must NOT hold the governance role"
        );
        require(params.riskLimiter != params.guardian, "risk limiter must differ from the guardian");
        require(
            !treasury.hasRole(treasury.GOVERNANCE_ROLE(), address(governor)),
            "governor must reach treasury only via the timelock"
        );

        // --- Governor parameters ---------------------------------------------
        require(governor.votingDelay() == params.votingDelay, "voting delay mismatch");
        require(governor.votingPeriod() == params.votingPeriod, "voting period mismatch");
        require(governor.proposalThreshold() == params.proposalThreshold, "proposal threshold mismatch");
        require(governor.timelock() == address(timelock), "governor wired to wrong timelock");
        require(address(governor.token()) == address(token), "governor wired to wrong token");

        // --- Quorum ramp --------------------------------------------------------
        require(governor.dynamicQuorumMinBps() == params.quorumMinBps, "quorum min mismatch");
        require(governor.dynamicQuorumMaxBps() == params.quorumMaxBps, "quorum max mismatch");
        require(
            governor.quorumLowSupplyThreshold() == params.initialSupply / 4,
            "quorum low threshold mismatch (expected initialSupply/4)"
        );
        require(
            governor.quorumHighSupplyThreshold() == (params.initialSupply * 9) / 10,
            "quorum high threshold mismatch (expected initialSupply*9/10)"
        );

        // --- Token ---------------------------------------------------------------
        require(token.totalSupply() == params.initialSupply, "token supply mismatch");
        require(token.balanceOf(params.initialRecipient) == params.initialSupply, "bootstrap supply not delivered");

        // --- Treasury tiers ---------------------------------------------------
        (uint48 lowDelay, uint256 lowCap, bool lowEnabled) = treasury.tierConfig(treasury.TIER_LOW());
        require(lowEnabled, "TIER_LOW disabled");
        assertMinTierDelay(treasury, params.minTierDelay);

        // ------------------------------------------------------------------
        // Post-deployment report
        // ------------------------------------------------------------------
        console2.log("--------------------------------------------------------");
        console2.log("All post-deployment wiring assertions passed.");
        console2.log("Bootstrap complete. Verify, then renounce the deployer");
        console2.log("admin role on the timelock:");
        console2.log("  cast send", address(timelock));
        console2.log("    \"renounceRole(bytes32,address)\"");
        console2.log("    <DEFAULT_ADMIN_ROLE> <deployer>");
        console2.log("--------------------------------------------------------");
        console2.log("Trust topology:");
        console2.log("  token holders -> governor -> timelock -> treasury");
        console2.log("Risk limiter (independent key):", params.riskLimiter);
        console2.log("Immutable min tier delay:", params.minTierDelay);
    }

    function assertMinTierDelay(DAOTreasuryExecutionEngine treasury, uint48 expected) internal view {
        require(treasury.minTierDelay() == expected, "min tier delay mismatch");
        for (uint8 tier = 0; tier <= treasury.MAX_TIER(); ++tier) {
            (uint48 delay,,) = treasury.tierConfig(tier);
            require(delay >= expected, "a shipped tier is below the immutable floor");
        }
    }

    function _readParams() internal view returns (DeployParams memory params) {
        params.tokenName = vm.envOr("TOKEN_NAME", string("Enterprise DAO Token"));
        params.tokenSymbol = vm.envOr("TOKEN_SYMBOL", string("EDAO"));
        params.initialRecipient = vm.envAddress("INITIAL_RECIPIENT");
        params.initialSupply = vm.envOr("INITIAL_SUPPLY", uint256(100_000_000e18));
        params.guardian = vm.envAddress("GUARDIAN_ADDRESS");
        params.riskLimiter = vm.envAddress("RISK_LIMITER_ADDRESS");
        params.minTierDelay = uint48(vm.envOr("TREASURY_MIN_TIER_DELAY", uint256(1 days)));
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
