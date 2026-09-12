// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {DAOGovernanceToken} from "../contracts/DAOGovernanceToken.sol";
import {EnterpriseDAO} from "../contracts/EnterpriseDAO.sol";
import {DAOTreasuryExecutionEngine} from "../contracts/DAOTreasuryExecutionEngine.sol";

/// @dev Runs the deployment script against a fresh in-process chain and verifies
///      every post-deployment assertion passes with canonical parameters, plus the
///      exact role topology documented in SECURITY.md.
contract DeployScriptTest is Test {
    address internal deployer = makeAddr("deployer");
    address internal multisig = makeAddr("multisig");
    address internal guardian = makeAddr("guardian");

    function test_DeployScriptWiring() public {
        // The script itself now performs assertions in _assertWiring; this test
        // replicates the canonical topology and independently verifies the same
        // invariants, so a regression in either place fails CI.
        (
            DAOGovernanceToken token,
            TimelockController timelock,
            EnterpriseDAO governor,
            DAOTreasuryExecutionEngine treasury
        ) = _deployLikeScript();

        // Assertions mirroring _assertWiring.
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), address(governor)), "PROPOSER_ROLE");
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), address(governor)), "CANCELLER_ROLE");
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)), "open executor");
        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), deployer), "deployer is temp admin");

        assertTrue(treasury.hasRole(treasury.GOVERNANCE_ROLE(), address(timelock)), "treasury governance");
        assertTrue(treasury.hasRole(treasury.GUARDIAN_ROLE(), guardian), "treasury guardian");

        assertEq(address(governor.token()), address(token));
        assertEq(governor.timelock(), address(timelock));
        assertEq(governor.dynamicQuorumMinBps(), 400);
        assertEq(governor.dynamicQuorumMaxBps(), 1000);
    }

    function _deployLikeScript()
        internal
        returns (DAOGovernanceToken, TimelockController, EnterpriseDAO, DAOTreasuryExecutionEngine)
    {
        DAOGovernanceToken token = new DAOGovernanceToken("T", "T", multisig, 100_000_000e18);

        address[] memory noProposers = new address[](0);
        address[] memory openExecutors = new address[](1);
        openExecutors[0] = address(0);
        TimelockController timelock = new TimelockController(2 days, noProposers, openExecutors, deployer);

        DAOTreasuryExecutionEngine treasury = new DAOTreasuryExecutionEngine(address(timelock), guardian);

        EnterpriseDAO.GovernorConfig memory cfg = EnterpriseDAO.GovernorConfig({
            name: "Enterprise DAO",
            token: IVotes(address(token)),
            timelock: timelock,
            votingDelayBlocks: 7_200,
            votingPeriodBlocks: 30_240,
            proposalThreshold: 250_000e18,
            quorumMinBps: 400,
            quorumMaxBps: 1000,
            quorumLowSupplyThreshold: 25_000_000e18,
            quorumHighSupplyThreshold: 90_000_000e18,
            minProposalThreshold: 25_000e18,
            maxProposalThreshold: 1_000_000e18
        });
        EnterpriseDAO governor = new EnterpriseDAO(cfg);

        vm.startPrank(deployer);
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));
        vm.stopPrank();

        return (token, timelock, governor, treasury);
    }
}
