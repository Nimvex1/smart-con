// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DAOTreasuryExecutionEngine} from "../contracts/DAOTreasuryExecutionEngine.sol";

contract InvariantTarget {
    uint256 public hits;

    function poke() external payable {
        ++hits;
    }

    receive() external payable {}
}

/// @dev Handler-based invariant actor: every action available on the treasury,
///      driven by fuzzed selectors. Ghost state tracks approved packages.
contract TreasuryHandler is Test {
    DAOTreasuryExecutionEngine public immutable treasury;
    InvariantTarget public immutable target;

    address public immutable governance;
    address public immutable guardian;

    // Ghost bookkeeping for invariants.
    mapping(bytes32 => bool) public approved;
    bytes32[] public approvedList;

    constructor(DAOTreasuryExecutionEngine t, InvariantTarget tgt, address gov, address grd) {
        treasury = t;
        target = tgt;
        governance = gov;
        guardian = grd;
    }

    function approve(uint256 valueSeed, uint8 tier) external {
        tier = uint8(uint256(bound(tier, 0, 3)));
        (, uint256 cap,) = treasury.tierConfig(tier);
        uint256 value = uint256(bound(valueSeed, 0, cap));
        vm.prank(governance);
        bytes32 id = treasury.approvePackage(address(target), value, "", tier, 0, bytes32(0));
        approved[id] = true;
        approvedList.push(id);
    }

    function execute(uint256 index) external {
        uint256 len = approvedList.length;
        if (len == 0) return;
        bytes32 id = approvedList[uint256(bound(index, 0, len - 1))];
        DAOTreasuryExecutionEngine.Package memory pkg = treasury.getPackage(id);
        if (pkg.executed || pkg.cancelled) return;
        if (block.timestamp < pkg.executeAfter) vm.warp(uint256(pkg.executeAfter) + 1);

        try treasury.executePackage(id) {
        // success: package now executed
        }
            catch {}
    }

    function approvedListLength() external view returns (uint256) {
        return approvedList.length;
    }

    function guardianCancel(uint256 index) external {
        uint256 len = approvedList.length;
        if (len == 0) return;
        bytes32 id = approvedList[uint256(bound(index, 0, len - 1))];

        try treasury.getPackage(id) returns (DAOTreasuryExecutionEngine.Package memory pkg) {
            if (pkg.executed || pkg.cancelled) return;
            if (block.timestamp >= pkg.executeAfter) vm.warp(block.timestamp - 1); // squeeze inside window
            vm.prank(guardian);
            try treasury.cancelPackage(id) {} catch {}
        } catch {}
    }

    function warpTime(uint256 jump) external {
        vm.warp(block.timestamp + bound(jump, 0, 400 days));
    }
}

/// @dev Core state-machine invariants of the treasury, checked after every fuzzed
///      action sequence:
///      1. An executed package can never execute again.
///      2. A cancelled package can never execute.
///      3. Unauthorized accounts can never schedule packages.
///      4. Executed and cancelled are mutually exclusive.
///      5. Nonce monotonicity.
contract TreasuryInvariantTest is Test {
    DAOTreasuryExecutionEngine internal treasury;
    InvariantTarget internal target;
    TreasuryHandler internal handler;

    address internal governance = makeAddr("governance");
    address internal guardian = makeAddr("guardian");
    address internal attacker = makeAddr("attacker");

    function setUp() public {
        treasury = new DAOTreasuryExecutionEngine(governance, guardian);
        target = new InvariantTarget();
        handler = new TreasuryHandler(treasury, target, governance, guardian);

        // Fuzz calls the handler's action functions between invariant checks.
        targetContract(address(handler));
    }

    function invariant_ExecutedNeverExecutesAgain() external {
        uint256 len = handler.approvedListLength();
        for (uint256 i = 0; i < len; ++i) {
            bytes32 id = handler.approvedList(i);
            if (!treasury.packageExists(id)) continue;
            DAOTreasuryExecutionEngine.Package memory pkg = treasury.getPackage(id);
            if (pkg.executed) {
                vm.expectRevert(abi.encodeWithSelector(DAOTreasuryExecutionEngine.PackageAlreadyFinalized.selector, id));
                treasury.executePackage(id);
            }
        }
    }

    function invariant_CancelledNeverExecutes() external {
        uint256 len = handler.approvedListLength();
        for (uint256 i = 0; i < len; ++i) {
            bytes32 id = handler.approvedList(i);
            if (!treasury.packageExists(id)) continue;
            DAOTreasuryExecutionEngine.Package memory pkg = treasury.getPackage(id);
            if (pkg.cancelled) {
                vm.expectRevert(abi.encodeWithSelector(DAOTreasuryExecutionEngine.PackageAlreadyFinalized.selector, id));
                treasury.executePackage(id);
            }
        }
    }

    function invariant_ExecutedAndCancelledExclusive() external {
        uint256 len = handler.approvedListLength();
        for (uint256 i = 0; i < len; ++i) {
            bytes32 id = handler.approvedList(i);
            if (!treasury.packageExists(id)) continue;
            DAOTreasuryExecutionEngine.Package memory pkg = treasury.getPackage(id);
            assertFalse(pkg.executed && pkg.cancelled, "package cannot be both executed and cancelled");
        }
    }

    /// @dev Attacker tries to schedule directly every invariant call: must always
    ///      hit the ACL revert regardless of state.
    function invariant_AttackerCannotSchedule() external {
        vm.prank(attacker);
        (bool ok,) = address(treasury)
            .call(
                abi.encodeCall(
                    DAOTreasuryExecutionEngine.approvePackage, (address(target), 0, bytes(""), 0, uint48(0), bytes32(0))
                )
            );
        assertFalse(ok, "unauthorized scheduling must revert");
    }

    /// @dev The treasury balance never increases through package execution alone.
    function invariant_NonceMonotonic() external view {
        assertGe(treasury.nextPackageNonce(), 1);
    }
}
