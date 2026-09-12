// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {VestingVault} from "../contracts/VestingVault.sol";

contract MintableERC20 is ERC20 {
    constructor() ERC20("Vest", "VST") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract VestingVaultTest is Test {
    VestingVault internal vault;
    MintableERC20 internal token;

    address internal beneficiary = makeAddr("beneficiary");
    address internal refundTo = makeAddr("refundTo");
    address internal rando = makeAddr("rando");

    uint256 internal constant AMOUNT = 1200e18;

    function setUp() public {
        // The test contract plays governance (GOVERNANCE_ROLE).
        vault = new VestingVault(address(this));
        token = new MintableERC20();
        token.mint(address(this), AMOUNT * 10);
        token.approve(address(vault), type(uint256).max);
    }

    function _create(uint48 start, uint48 cliff, uint48 duration, bool revocable) internal returns (uint256 id) {
        id = vault.createSchedule(token, beneficiary, AMOUNT, start, cliff, duration, revocable);
    }

    function test_FullVestFlow() public {
        uint48 start = uint48(block.timestamp);
        uint256 id = _create(start, 0, 365 days, false);

        assertEq(vault.claimable(id), 0, "nothing vested at start");

        vm.warp(start + 365 days);
        assertEq(vault.claimable(id), AMOUNT, "fully vested at duration end");

        // Anyone may trigger the payout; funds only reach the beneficiary.
        vm.prank(rando);
        vault.claim(id);
        assertEq(token.balanceOf(beneficiary), AMOUNT);
        assertEq(token.balanceOf(address(vault)), 0);
    }

    function test_CliffThenLinear() public {
        uint48 start = uint48(block.timestamp);
        uint256 id = _create(start, 90 days, 360 days, false);

        vm.warp(start + 89 days);
        assertEq(vault.claimable(id), 0, "cliff not reached");

        vm.warp(start + 180 days);
        assertEq(vault.claimable(id), AMOUNT / 2, "linear halfway through duration");

        // Partial claims accumulate to the total.
        vault.claim(id);
        assertEq(token.balanceOf(beneficiary), AMOUNT / 2);
        vm.warp(start + 360 days);
        vault.claim(id);
        assertEq(token.balanceOf(beneficiary), AMOUNT);
    }

    function test_ClaimBeforeVestingReverts() public {
        uint256 id = _create(uint48(block.timestamp), 30 days, 360 days, false);
        vm.expectRevert(abi.encodeWithSelector(VestingVault.NothingVested.selector, id));
        vault.claim(id);
    }

    function test_RevokeRefundsUnvestedKeepsVested() public {
        uint48 start = uint48(block.timestamp);
        uint256 id = _create(start, 0, 360 days, true);

        vm.warp(start + 180 days); // half vested
        vault.revoke(id, refundTo);

        assertEq(token.balanceOf(refundTo), AMOUNT / 2, "unvested refunded");
        assertEq(vault.claimable(id), AMOUNT / 2, "vested stays claimable");

        vault.claim(id);
        assertEq(token.balanceOf(beneficiary), AMOUNT / 2);

        VestingVault.Schedule memory s = vault.getSchedule(id);
        assertTrue(s.revoked);
    }

    function test_RevokeFreezesVesting() public {
        uint48 start = uint48(block.timestamp);
        uint256 id = _create(start, 0, 360 days, true);

        vm.warp(start + 90 days);
        vault.revoke(id, refundTo);

        vm.warp(start + 360 days); // time passes, vesting must not grow
        assertEq(vault.claimable(id), AMOUNT / 4, "frozen at revocation point");
    }

    function test_IrrevocableAndDoubleRevokeRevert() public {
        uint256 id = _create(uint48(block.timestamp), 0, 360 days, false);
        vm.expectRevert(abi.encodeWithSelector(VestingVault.Irrevocable.selector, id));
        vault.revoke(id, refundTo);

        uint256 id2 = _create(uint48(block.timestamp), 0, 360 days, true);
        vault.revoke(id2, refundTo);
        vm.expectRevert(abi.encodeWithSelector(VestingVault.AlreadyRevoked.selector, id2));
        vault.revoke(id2, refundTo);
    }

    function test_CreateValidation() public {
        vm.expectRevert(VestingVault.InvalidBeneficiary.selector);
        vault.createSchedule(token, address(0), AMOUNT, 0, 0, 360 days, false);

        vm.expectRevert(VestingVault.InvalidAmount.selector);
        vault.createSchedule(token, beneficiary, 0, 0, 0, 360 days, false);

        vm.expectRevert(VestingVault.InvalidDuration.selector);
        vault.createSchedule(token, beneficiary, AMOUNT, 0, 0, 0, false);

        vm.expectRevert(VestingVault.InvalidCliff.selector);
        vault.createSchedule(token, beneficiary, AMOUNT, 0, 361 days, 360 days, false);
    }

    function test_OnlyGovernanceManages() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, rando, vault.GOVERNANCE_ROLE()
            )
        );
        vm.prank(rando);
        vault.createSchedule(token, beneficiary, AMOUNT, 0, 0, 360 days, false);

        uint256 id = _create(uint48(block.timestamp), 0, 360 days, true);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, rando, vault.GOVERNANCE_ROLE()
            )
        );
        vm.prank(rando);
        vault.revoke(id, refundTo);
    }

    function test_UnknownScheduleReverts() public {
        vm.expectRevert(abi.encodeWithSelector(VestingVault.ScheduleNotFound.selector, 999));
        vault.claim(999);
    }
}
