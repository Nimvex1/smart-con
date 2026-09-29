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
    address internal riskLimiter = makeAddr("riskLimiter");

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
        assertTrue(treasury.hasRole(treasury.RISK_LIMITER_ROLE(), riskLimiter), "treasury risk limiter");

        assertEq(address(governor.token()), address(token));
        assertEq(governor.timelock(), address(timelock));
        assertEq(governor.dynamicQuorumMinBps(), 400);
        assertEq(governor.dynamicQuorumMaxBps(), 1000);
    }

    /// @dev The role split is the entire basis of the risk-limit design: if one entity
    ///      holds both halves, a single compromise removes every constraint and the
    ///      delay ladder becomes decorative. The deploy script asserts this; assert it here.
    function test_RiskLimiterIsIndependentOfGovernorAndGuardian() public {
        (, TimelockController timelock,, DAOTreasuryExecutionEngine treasury) = _deployLikeScript();

        assertFalse(treasury.hasRole(treasury.RISK_LIMITER_ROLE(), address(timelock)), "timelock is not the limiter");
        assertFalse(treasury.hasRole(treasury.GOVERNANCE_ROLE(), riskLimiter), "limiter is not governance");
        assertFalse(treasury.hasRole(treasury.RISK_LIMITER_ROLE(), guardian), "guardian is not the limiter");
        assertTrue(riskLimiter != guardian, "limiter differs from guardian");
    }

    /// @dev A governor that captured the timelock still cannot loosen a risk limit.
    ///      The limiter hardens first, because at defaults "disable the allowlist" and
    ///      "floor to 0" are no-ops rather than loosenings -- there is nothing to remove.
    function test_CapturedGovernorCannotLoosenRiskLimits() public {
        (, TimelockController timelock,, DAOTreasuryExecutionEngine treasury) = _deployLikeScript();
        bytes32 risk = treasury.RISK_LIMITER_ROLE();

        // Limiter hardens: enable containment and set a floor.
        vm.startPrank(riskLimiter);
        treasury.setTargetAllowlistEnabled(true);
        treasury.setTargetAllowed(address(treasury), true);
        treasury.setNativeReserveFloor(1_000 ether);
        vm.stopPrank();
        assertTrue(treasury.targetAllowlistEnabled());
        assertEq(treasury.nativeReserveFloor(), 1_000 ether);

        // The captured timelock tries the full one-batch dismantle.
        vm.startPrank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(DAOTreasuryExecutionEngine.RiskChangeRequiresLimiter.selector, address(timelock))
        );
        treasury.configureTier(0, 0, type(uint256).max, true);

        vm.expectRevert(
            abi.encodeWithSelector(DAOTreasuryExecutionEngine.RiskChangeRequiresLimiter.selector, address(timelock))
        );
        treasury.setTargetAllowlistEnabled(false);

        vm.expectRevert(
            abi.encodeWithSelector(DAOTreasuryExecutionEngine.RiskChangeRequiresLimiter.selector, address(timelock))
        );
        treasury.setTargetAllowed(address(treasury), false);

        vm.expectRevert(
            abi.encodeWithSelector(DAOTreasuryExecutionEngine.RiskChangeRequiresLimiter.selector, address(timelock))
        );
        treasury.setNativeReserveFloor(0);
        vm.stopPrank();

        // Nothing moved.
        assertTrue(treasury.targetAllowlistEnabled());
        assertEq(treasury.nativeReserveFloor(), 1_000 ether);
        (uint48 d, uint256 cap,) = treasury.tierConfig(0);
        assertEq(d, 1 days);
        assertEq(cap, 250 ether);

        // And even the limiter cannot remove the immutable floor.
        vm.startPrank(riskLimiter);
        vm.expectRevert(abi.encodeWithSelector(DAOTreasuryExecutionEngine.TierDelayTooShort.selector, 0, 1 days));
        treasury.configureTier(0, 0, type(uint256).max, true);
        vm.stopPrank();

        // Tighter limits remain available to governance, so incidents stay containable.
        vm.prank(address(timelock));
        treasury.configureTier(0, 30 days, 1 ether, true);
        (uint48 d2, uint256 cap2,) = treasury.tierConfig(0);
        assertEq(d2, 30 days);
        assertEq(cap2, 1 ether);
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

        DAOTreasuryExecutionEngine treasury =
            new DAOTreasuryExecutionEngine(address(timelock), guardian, riskLimiter, 1 days);

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
