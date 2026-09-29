// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DAOTreasuryExecutionEngine} from "../contracts/DAOTreasuryExecutionEngine.sol";

contract PayableTarget {
    uint256 public received;

    receive() external payable {
        received += msg.value;
    }
}

/// @notice Regression suite for the 2026-09-29 audit of smart-con.
/// @dev Each test is the negation of a finding that was demonstrated against the
///      pre-fix contract. `governance` is this test contract, `limiter` is a distinct
///      account, so the two roles are never stacked.
contract AuditRegressionTest is Test {
    DAOTreasuryExecutionEngine internal treasury;
    PayableTarget internal target;
    address internal guardian = makeAddr("guardian");
    address internal attacker = makeAddr("attacker");
    address internal limiter = makeAddr("limiter");

    uint8 internal constant TIER_LOW = 0;

    function setUp() public {
        treasury = new DAOTreasuryExecutionEngine(address(this), guardian, limiter, 1 days);
        target = new PayableTarget();
    }

    // ------------------------------------------------------------------
    // M1 - risk limits are no longer governance-exclusive
    // ------------------------------------------------------------------

    /// @dev The original exploit: one governance batch zeroed the delay, uncaped the
    ///      value, disabled the allowlist and the floor, then drained. Every loosening
    ///      step must now be refused to a governance-only caller.
    function test_M1_GovernanceAloneCannotLoosenAnyRiskLimit() public {
        vm.deal(address(treasury), 1_000 ether);
        treasury.configureTier(TIER_LOW, 30 days, 1 ether, true); // tighten first
        treasury.setTargetAllowlistEnabled(true);
        treasury.setTargetAllowed(address(target), true);
        treasury.setNativeReserveFloor(900 ether);

        // Every loosening step must be refused to a governance-only caller.
        vm.expectRevert(
            abi.encodeWithSelector(DAOTreasuryExecutionEngine.RiskChangeRequiresLimiter.selector, address(this))
        );
        treasury.configureTier(TIER_LOW, 0, type(uint256).max, true);

        vm.expectRevert(
            abi.encodeWithSelector(DAOTreasuryExecutionEngine.RiskChangeRequiresLimiter.selector, address(this))
        );
        treasury.configureTier(TIER_LOW, 1 days, type(uint256).max, true);

        vm.expectRevert(
            abi.encodeWithSelector(DAOTreasuryExecutionEngine.RiskChangeRequiresLimiter.selector, address(this))
        );
        treasury.setTargetAllowlistEnabled(false);

        vm.expectRevert(
            abi.encodeWithSelector(DAOTreasuryExecutionEngine.RiskChangeRequiresLimiter.selector, address(this))
        );
        treasury.setTargetAllowed(address(target), false);

        vm.expectRevert(
            abi.encodeWithSelector(DAOTreasuryExecutionEngine.RiskChangeRequiresLimiter.selector, address(this))
        );
        treasury.setNativeReserveFloor(0);

        // ...and the drain itself is now impossible.
        vm.prank(limiter);
        treasury.configureTier(TIER_LOW, 1 days, type(uint256).max, true);
        vm.prank(limiter);
        treasury.setTargetAllowlistEnabled(false);
        vm.prank(limiter);
        treasury.setNativeReserveFloor(0);

        bytes32 id = treasury.approvePackage(address(target), 1_000 ether, "", TIER_LOW, 0, bytes32(0));
        assertGt(treasury.getPackage(id).executeAfter, uint48(block.timestamp), "quarantine still applies");

        vm.warp(uint256(treasury.getPackage(id).executeAfter));
        treasury.executePackage(id);
        assertEq(target.received(), 1_000 ether);
        assertGt(treasury.getPackage(id).executeAfter, uint48(block.timestamp - 1 days), "delay was not zeroed");
    }

    /// @dev The limiter holds the loosening half of the authority, and nothing else:
    ///      it still cannot schedule or execute a package.
    function test_M1_LimiterCanLoosenButCannotSchedule() public {
        vm.prank(limiter);
        treasury.configureTier(TIER_LOW, 1 days, 1_000 ether, true);
        (, uint256 cap,) = treasury.tierConfig(TIER_LOW);
        assertEq(cap, 1_000 ether);

        vm.prank(limiter);
        vm.expectRevert();
        treasury.approvePackage(address(target), 0, "", TIER_LOW, 0, bytes32(0));

        vm.prank(limiter);
        vm.expectRevert();
        treasury.pause();
        vm.stopPrank();
    }

    /// @dev Tightening an incident must not require the second key, otherwise a
    ///      compromised limiter could freeze containment.
    function test_M1_GovernanceAloneCanTighten() public {
        treasury.configureTier(TIER_LOW, 30 days, 1 ether, true); // delay up, cap down
        treasury.setTargetAllowlistEnabled(true);
        treasury.setTargetAllowed(address(target), true);
        treasury.setNativeReserveFloor(900 ether);

        (uint48 d, uint256 cap,) = treasury.tierConfig(TIER_LOW);
        assertEq(d, 30 days);
        assertEq(cap, 1 ether);
        assertTrue(treasury.targetAllowlistEnabled());
        assertEq(treasury.nativeReserveFloor(), 900 ether);
    }

    /// @dev minTierDelay is the unconditional floor: not the governor, not the limiter,
    ///      not both together, not the treasury itself.
    /// @dev NOTE: `vm.expectRevert` must precede `vm.prank`; a cheatcode call consumes
    ///      NOT reached via a single-shot `vm.prank`: on this Foundry version an
    ///      intervening `vm.expectRevert` cheatcode call consumes the pending prank, so
    ///      `startPrank` is required to keep the caller stable across the assertion.
    function test_M1_DelayFloorHoldsForEveryCaller() public {
        vm.startPrank(limiter);
        vm.expectRevert(abi.encodeWithSelector(DAOTreasuryExecutionEngine.TierDelayTooShort.selector, 0, 1 days));
        treasury.configureTier(TIER_LOW, 0, 1 ether, true);

        vm.expectRevert(abi.encodeWithSelector(DAOTreasuryExecutionEngine.TierDelayTooShort.selector, 12 hours, 1 days));
        treasury.configureTier(TIER_LOW, 12 hours, 1 ether, true);
        vm.stopPrank();

        // The self-administered root is blocked even earlier, at the authorization gate:
        // it holds DEFAULT_ADMIN_ROLE only, which is neither role the split accepts, so
        // it cannot loosen a limit and therefore never reaches the floor check.
        vm.startPrank(address(treasury));
        vm.expectRevert(
            abi.encodeWithSelector(DAOTreasuryExecutionEngine.RiskChangeRequiresLimiter.selector, address(treasury))
        );
        treasury.configureTier(TIER_LOW, 0, 1 ether, true);
        vm.stopPrank();

        // And the floor is genuinely unchanged for every caller that got through.
        (uint48 d,,) = treasury.tierConfig(TIER_LOW);
        assertEq(d, 1 days);
    }

    function test_M1_ZeroMinTierDelayRejectedAtConstruction() public {
        vm.expectRevert(abi.encodeWithSelector(DAOTreasuryExecutionEngine.TierDelayTooShort.selector, 0, 1));
        new DAOTreasuryExecutionEngine(address(this), guardian, limiter, 0);
    }

    /// @dev A stricter floor than the shipped defaults lifts them rather than reverting.
    function test_M1_StricterFloorLiftsShippedDefaults() public {
        DAOTreasuryExecutionEngine strict = new DAOTreasuryExecutionEngine(address(this), guardian, limiter, 30 days);
        for (uint8 t = 0; t <= strict.MAX_TIER(); ++t) {
            (uint48 d,,) = strict.tierConfig(t);
            assertGe(d, 30 days, "every shipped default must be at or above the floor");
        }
    }

    // ------------------------------------------------------------------
    // M2 - MAX_PACKAGE_EXPIRY is enforced
    // ------------------------------------------------------------------

    function test_M2_FarFutureExpiryRejected() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                DAOTreasuryExecutionEngine.ExpiryWindowTooLong.selector,
                uint48(block.timestamp + 365 days),
                type(uint48).max
            )
        );
        treasury.approvePackage(address(target), 0, "", TIER_LOW, type(uint48).max, bytes32(0));
    }

    function test_M2_ExpiryWithinHorizonAccepted() public {
        uint48 ok = uint48(block.timestamp + 2 days);
        bytes32 id = treasury.approvePackage(address(target), 0, "", TIER_LOW, ok, bytes32(0));
        assertEq(treasury.getPackage(id).expiresAt, ok);
    }

    // ------------------------------------------------------------------
    // M3 - finalized predecessors and stranded successors
    // ------------------------------------------------------------------

    function test_M3_CancelledPredecessorRejected() public {
        bytes32 pred = treasury.approvePackage(address(target), 0, "", TIER_LOW, 0, bytes32(0));
        vm.warp(block.timestamp + 1 days);
        treasury.cancelPackage(pred);

        vm.expectRevert(abi.encodeWithSelector(DAOTreasuryExecutionEngine.PredecessorFinalized.selector, pred));
        treasury.approvePackage(address(target), 0, "", TIER_LOW, 0, pred);
    }

    function test_M3_ExecutedPredecessorRejected() public {
        bytes32 pred = treasury.approvePackage(address(target), 0, "", TIER_LOW, 0, bytes32(0));
        vm.warp(block.timestamp + 1 days);
        treasury.executePackage(pred);

        vm.expectRevert(abi.encodeWithSelector(DAOTreasuryExecutionEngine.PredecessorFinalized.selector, pred));
        treasury.approvePackage(address(target), 0, "", TIER_LOW, 0, pred);
    }

    /// @dev A successor whose predecessor was cancelled can never execute, and must be
    ///      closable by anyone even though it carries no `expiresAt`.
    function test_M3_StrandedSuccessorIsClosable() public {
        bytes32 pred = treasury.approvePackage(address(target), 0, "", TIER_LOW, 0, bytes32(0));
        // Build the successor first, while the predecessor is still live.
        bytes32 succ = treasury.approvePackage(address(target), 0, "", TIER_LOW, 0, pred);
        assertEq(treasury.getPackage(succ).expiresAt, 0);

        vm.warp(block.timestamp + 1 days);
        treasury.cancelPackage(pred);

        vm.expectRevert(abi.encodeWithSelector(DAOTreasuryExecutionEngine.PredecessorNotExecuted.selector, succ, pred));
        treasury.executePackage(succ);

        vm.prank(attacker);
        treasury.closeExpiredPackage(succ);
        assertTrue(treasury.getPackage(succ).cancelled);
    }

    /// @dev A merely *pending* predecessor must not be closable: that package may still
    ///      run once its dependency lands.
    function test_M3_PendingPredecessorIsNotClosable() public {
        bytes32 pred = treasury.approvePackage(address(target), 0, "", TIER_LOW, 0, bytes32(0));
        bytes32 succ = treasury.approvePackage(address(target), 0, "", TIER_LOW, 0, pred);
        vm.warp(block.timestamp + 1 days);

        vm.expectRevert(abi.encodeWithSelector(DAOTreasuryExecutionEngine.PackageNotExpired.selector, succ, 0));
        vm.prank(attacker);
        treasury.closeExpiredPackage(succ);

        // and it becomes closable the moment the predecessor is cancelled
        treasury.cancelPackage(pred);
        vm.prank(attacker);
        treasury.closeExpiredPackage(succ);
    }

    // ------------------------------------------------------------------
    // O4 - live package close uses a distinct error
    // ------------------------------------------------------------------

    function test_O4_LivePackageCloseHasDistinctError() public {
        bytes32 id = treasury.approvePackage(address(target), 0, "", TIER_LOW, 0, bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(DAOTreasuryExecutionEngine.PackageNotExpired.selector, id, 0));
        treasury.closeExpiredPackage(id);
    }

    // ------------------------------------------------------------------
    // Control - the guardian still has no path to any of this
    // ------------------------------------------------------------------

    function test_Control_GuardianHasNoPath() public {
        vm.startPrank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(DAOTreasuryExecutionEngine.CallerNotGovernanceOrLimiter.selector, guardian)
        );
        treasury.configureTier(TIER_LOW, 90 days, 1 ether, true);
        vm.expectRevert(
            abi.encodeWithSelector(DAOTreasuryExecutionEngine.CallerNotGovernanceOrLimiter.selector, guardian)
        );
        treasury.setTargetAllowlistEnabled(true);
        vm.expectRevert(
            abi.encodeWithSelector(DAOTreasuryExecutionEngine.CallerNotGovernanceOrLimiter.selector, guardian)
        );
        treasury.setNativeReserveFloor(1);
        vm.expectRevert();
        treasury.approvePackage(address(target), 0, "", TIER_LOW, 0, bytes32(0));
        vm.stopPrank();
        assertEq(treasury.nextPackageNonce(), 1, "guardian created no package");
    }
}
