// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {DAOTreasuryExecutionEngine} from "../contracts/DAOTreasuryExecutionEngine.sol";

contract CallTarget {
    uint256 public flag;
    uint256 public lastNativeReceived;

    function setFlag(uint256 v) external payable {
        flag = v;
        lastNativeReceived = msg.value;
    }

    function gimme() external payable {}

    receive() external payable {}
}

/// @dev Property and fuzz tests over the strengthened treasury package model:
///      package ids, tiers, delays, values, expiry windows, predecessor ordering,
///      allowlist and reserve floors, plus guardian cancellation timing.
contract TreasuryFuzzTest is Test {
    DAOTreasuryExecutionEngine internal treasury;
    CallTarget internal target;

    address internal guardian = makeAddr("guardian");
    address internal rando = makeAddr("rando");

    uint8 internal constant MAX_TIER = 3;
    uint48 internal constant MAX_DELAY = 365 days;

    function setUp() public {
        treasury = new DAOTreasuryExecutionEngine(address(this), guardian);
        target = new CallTarget();
    }

    // ------------------------------------------------------------------
    // Package id / tier / delay / value fuzz
    // ------------------------------------------------------------------

    /// @dev Any (target, value, calldata, tier, nonce) maps to a unique id that the
    ///      contract itself can recompute via packageHash.
    function testFuzz_PackageIdCommitment(uint96 valueSeed, uint8 tier, uint48 delay, uint256 flagValue) public {
        tier = uint8(bound(tier, 0, MAX_TIER));
        delay = uint48(bound(delay, 0, MAX_DELAY));
        (, uint256 cap,) = treasury.tierConfig(tier);
        valueSeed = uint96(bound(valueSeed, 0, cap));
        bytes memory data = abi.encodeCall(CallTarget.setFlag, (flagValue));

        bytes32 id = treasury.approvePackage(address(target), valueSeed, data, tier, 0, bytes32(0));
        uint256 nonce = treasury.nextPackageNonce() - 1;
        assertEq(id, treasury.packageHash(address(target), valueSeed, data, tier, nonce));
    }

    /// @dev Approval with a value above the tier cap must always revert, for any tier
    ///      and any cap value (boundary fuzz).
    function testFuzz_ValueCapBoundary(uint8 tier, uint256 cap, uint256 delta) public {
        tier = uint8(bound(tier, 0, MAX_TIER));
        cap = bound(cap, 0, type(uint128).max);
        delta = bound(delta, 1, type(uint128).max);

        treasury.configureTier(tier, 1 days, cap, true);

        vm.expectRevert(
            abi.encodeWithSelector(DAOTreasuryExecutionEngine.NativeValueTooHigh.selector, cap + delta, cap)
        );
        treasury.approvePackage(address(target), cap + delta, "", tier, 0, bytes32(0));

        // Exactly at cap: allowed.
        bytes32 id = treasury.approvePackage(address(target), cap, "", tier, 0, bytes32(0));
        assertTrue(treasury.packageExists(id));
    }

    /// @dev Tier reconfiguration bounds: delays above MAX_TIER_DELAY always revert.
    function testFuzz_TierDelayBound(uint48 delay) public {
        if (delay <= MAX_DELAY) {
            treasury.configureTier(0, delay, 1 ether, true);
            (uint48 d,,) = treasury.tierConfig(0);
            assertEq(d, delay);
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(DAOTreasuryExecutionEngine.TierDelayTooLong.selector, delay, MAX_DELAY)
            );
            treasury.configureTier(0, delay, 1 ether, true);
        }
    }

    /// @dev Cancellation timing: guardians can only cancel while `now < executeAfter`;
    ///      after that the revert must carry the exact executeAfter timepoint.
    function testFuzz_GuardianCancelTiming(uint8 tier, uint48 delay, uint256 elapsed) public {
        tier = uint8(bound(tier, 0, MAX_TIER));
        delay = uint48(bound(delay, 1, 30 days));
        treasury.configureTier(tier, delay, type(uint256).max, true);

        bytes32 id = treasury.approvePackage(address(target), 0, "", tier, 0, bytes32(0));
        DAOTreasuryExecutionEngine.Package memory pkg = treasury.getPackage(id);
        uint48 executeAfter = pkg.executeAfter;

        elapsed = bound(elapsed, 0, 60 days);
        vm.warp(block.timestamp + elapsed);

        if (block.timestamp < executeAfter) {
            vm.prank(guardian);
            treasury.cancelPackage(id);
            assertTrue(treasury.getPackage(id).cancelled);
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(DAOTreasuryExecutionEngine.GuardianCancelWindowClosed.selector, id, executeAfter)
            );
            vm.prank(guardian);
            treasury.cancelPackage(id);
        }
    }

    /// @dev Expiry: within [executeAfter, expiresAt) execution works; at/after
    ///      expiresAt the package is dead and closeExpiredPackage finalizes it.
    function testFuzz_ExpiryWindow(uint8 tier, uint48 delay, uint48 extra, uint256 jump) public {
        tier = uint8(bound(tier, 0, MAX_TIER));
        delay = uint48(bound(delay, 0, 30 days));
        extra = uint48(bound(extra, 1, 30 days));
        treasury.configureTier(tier, delay, type(uint256).max, true);

        uint48 expiresAt = uint48(block.timestamp + delay + extra);
        bytes32 id = treasury.approvePackage(address(target), 0, "", tier, expiresAt, bytes32(0));
        DAOTreasuryExecutionEngine.Package memory pkg = treasury.getPackage(id);
        uint48 executeAfter = pkg.executeAfter;
        assertEq(executeAfter, uint48(block.timestamp + delay));

        jump = bound(jump, 0, uint256(delay) + extra + 1);
        vm.warp(uint256(executeAfter) + jump);

        if (block.timestamp < expiresAt) {
            treasury.executePackage(id);
            assertTrue(treasury.getPackage(id).executed);
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(DAOTreasuryExecutionEngine.PackageExpiredError.selector, id, expiresAt)
            );
            treasury.executePackage(id);
            // Still finalizable as expired by anyone.
            treasury.closeExpiredPackage(id);
            assertTrue(treasury.getPackage(id).cancelled);
        }
    }

    /// @dev Predecessor ordering: a dependent package can only execute after its
    ///      predecessor, for arbitrary approval orders and delays.
    function testFuzz_PredecessorOrdering(uint48 d1, uint48 d2, bool executeFirstFirst) public {
        d1 = uint48(bound(d1, 0, 30 days));
        d2 = uint48(bound(d2, 0, 30 days));
        treasury.configureTier(0, d1, type(uint256).max, true);
        treasury.configureTier(1, d2, type(uint256).max, true);

        bytes32 first = treasury.approvePackage(address(target), 0, "", 0, 0, bytes32(0));
        bytes32 second = treasury.approvePackage(address(target), 0, "", 1, 0, first);

        vm.warp(block.timestamp + 30 days + 2);

        if (executeFirstFirst) {
            treasury.executePackage(first);
            treasury.executePackage(second); // predecessor satisfied
            assertTrue(treasury.getPackage(second).executed);
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(DAOTreasuryExecutionEngine.PredecessorNotExecuted.selector, second, first)
            );
            treasury.executePackage(second);
            treasury.executePackage(first);
            treasury.executePackage(second);
            assertTrue(treasury.getPackage(second).executed);
        }
    }

    /// @dev Approving a dependency on an unknown package must revert.
    function testFuzz_PredecessorMustExist(uint8 tier, uint48 delay, bytes32 bogus) public {
        tier = uint8(bound(tier, 0, MAX_TIER));
        delay = uint48(bound(delay, 0, 30 days));
        treasury.configureTier(tier, delay, type(uint256).max, true);

        vm.assume(bogus != bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(DAOTreasuryExecutionEngine.PackageNotFound.selector, bogus));
        treasury.approvePackage(address(target), 0, "", tier, 0, bogus);
    }

    /// @dev Allowlist: once enabled, only listed targets may be scheduled, for any
    ///      fuzzed target address and tier.
    function testFuzz_AllowlistBlocksUnlistedTargets(address anyTarget, uint8 tier) public {
        tier = uint8(bound(tier, 0, MAX_TIER));
        vm.assume(anyTarget != address(0));

        // Disabled by default: anything goes.
        assertFalse(treasury.targetAllowlistEnabled());

        treasury.setTargetAllowlistEnabled(true);
        assertTrue(treasury.targetAllowlistEnabled());

        vm.expectRevert(abi.encodeWithSelector(DAOTreasuryExecutionEngine.TargetNotAllowed.selector, anyTarget));
        treasury.approvePackage(anyTarget, 0, "", tier, 0, bytes32(0));

        // Governance lists the target: scheduling works again.
        treasury.setTargetAllowed(address(target), true);
        assertTrue(treasury.targetAllowlist(address(target)));
    }

    /// @dev Reserve floor: execution pushing the native balance below the floor
    ///      must revert; above it, succeed.
    function testFuzz_NativeReserveFloor(uint256 balance, uint256 floor, uint256 spend) public {
        balance = bound(balance, 0, 1000 ether);
        floor = bound(floor, 0, 1000 ether);
        spend = bound(spend, 1, 250 ether); // TIER_LOW cap

        treasury.configureTier(0, 0, 250 ether, true);
        treasury.setNativeReserveFloor(floor);
        deal(address(treasury), balance);

        bytes32 id = treasury.approvePackage(address(target), spend, "", 0, 0, bytes32(0));
        vm.warp(block.timestamp + 1);

        if (balance >= spend && balance - spend >= floor) {
            treasury.executePackage(id);
            assertEq(address(treasury).balance, balance - spend);
        } else if (balance >= spend) {
            vm.expectRevert(
                abi.encodeWithSelector(DAOTreasuryExecutionEngine.ReserveFloorBreached.selector, balance, floor)
            );
            treasury.executePackage(id);
        } else {
            vm.expectRevert(); // call forwards more ETH than held: execution fails
            treasury.executePackage(id);
        }
    }

    /// @dev Zero-allowance-style unauthorized scheduling: no address other than
    ///      governance can ever create a package.
    function testFuzz_UnauthorizedCanNeverSchedule(
        address caller,
        uint8 tier,
        uint256 value,
        uint48 expiry,
        bytes32 pred
    ) public {
        tier = uint8(bound(tier, 0, MAX_TIER));
        vm.assume(caller != address(this)); // the test contract holds GOVERNANCE_ROLE
        // Neutralise the other revert paths so the ONLY failure cause is the ACL check:
        // value within cap, tier enabled, expiry well after the tier delay.
        treasury.configureTier(tier, 1 days, type(uint256).max, true);
        uint48 safeExpiry = uint48(block.timestamp + 2 days);
        value = bound(value, 0, type(uint256).max);
        pred = bytes32(0); // neutralise dependency-check revert

        bytes32 role = treasury.GOVERNANCE_ROLE(); // read BEFORE prank
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, role));
        treasury.approvePackage(address(target), value, "", tier, safeExpiry, pred);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function packageTimes(bytes32 id)
        internal
        view
        returns (uint48 executeAfter, uint48 expiresAt, uint8 tier, bytes32 predecessor)
    {
        DAOTreasuryExecutionEngine.Package memory pkg = treasury.getPackage(id);
        return (pkg.executeAfter, pkg.expiresAt, pkg.tier, pkg.predecessor);
    }
}

/// @dev Thin wrapper exposing tier caps for fuzzing convenience.
contract TierCapReader {
    DAOTreasuryExecutionEngine public immutable treasury;

    constructor(DAOTreasuryExecutionEngine t) {
        treasury = t;
    }

    function cap(uint8 tier) external view returns (uint256) {
        (, uint256 cap,) = treasury.tierConfig(tier);
        return cap;
    }
}
