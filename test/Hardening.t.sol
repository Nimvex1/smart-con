// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {DAOTreasuryExecutionEngine} from "../contracts/DAOTreasuryExecutionEngine.sol";
import {DAOGovernanceToken} from "../contracts/DAOGovernanceToken.sol";
import {EnterpriseDAO} from "../contracts/EnterpriseDAO.sol";

contract MintableERC20 is ERC20 {
    constructor() ERC20("Spend", "SPND") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract FlagTarget {
    uint256 public flag;

    function setFlag(uint256 v) external payable {
        flag = v;
    }
}

/// @dev Coverage for the v3 hardening + usability features:
///      expiry cap, execution-time policy revalidation, minimum tier delay,
///      dataHash retention, spend limiter, direct-target ERC20 floors,
///      batch scheduling/sweeping, packageState, predecessor clearing,
///      allowlist self-guard, and governor voting floors.
contract HardeningTest is Test {
    DAOTreasuryExecutionEngine internal treasury;
    FlagTarget internal target;
    MintableERC20 internal spend;

    address internal guardian = makeAddr("guardian");

    uint8 internal constant TIER_LOW = 0;

    function setUp() public {
        treasury = new DAOTreasuryExecutionEngine(address(this), guardian);
        target = new FlagTarget();
        spend = new MintableERC20();
    }

    function _approve(address t, uint256 v, bytes memory d, uint8 tier) internal returns (bytes32 id) {
        id = treasury.approvePackage(t, v, d, tier, 0, bytes32(0));
    }

    // ------------------------------------------------------------------
    // Expiry cap
    // ------------------------------------------------------------------

    function test_ExpiryBeyondMaxReverts() public {
        uint48 farFuture = uint48(block.timestamp + 366 days);
        vm.expectRevert(
            abi.encodeWithSelector(
                DAOTreasuryExecutionEngine.ExpiryTooFar.selector, farFuture, uint48(block.timestamp + 365 days)
            )
        );
        treasury.approvePackage(address(target), 0, "", TIER_LOW, farFuture, bytes32(0));
    }

    function test_ExpiryAtMaxSucceeds() public {
        uint48 atMax = uint48(block.timestamp + 365 days);
        bytes32 id = treasury.approvePackage(address(target), 0, "", TIER_LOW, atMax, bytes32(0));
        assertTrue(treasury.packageExists(id));
    }

    // ------------------------------------------------------------------
    // Execution-time policy revalidation
    // ------------------------------------------------------------------

    function test_AllowlistEnabledAfterSchedulingBlocksExecution() public {
        bytes32 id = _approve(address(target), 0, abi.encodeCall(FlagTarget.setFlag, (1)), TIER_LOW);
        treasury.setTargetAllowed(address(treasury), true);
        treasury.setTargetAllowed(address(target), false);
        treasury.setTargetAllowlistEnabled(true);
        vm.warp(block.timestamp + 1 days + 1);
        vm.expectRevert(abi.encodeWithSelector(DAOTreasuryExecutionEngine.TargetNotAllowed.selector, address(target)));
        treasury.executePackage(id);
        // Listing the target unblocks it.
        treasury.setTargetAllowed(address(target), true);
        treasury.executePackage(id);
        assertEq(target.flag(), 1);
    }

    function test_CapLoweredAfterSchedulingBlocksExecution() public {
        deal(address(treasury), 250 ether);
        bytes32 id = treasury.approvePackage(address(target), 250 ether, "", TIER_LOW, 0, bytes32(0));
        treasury.configureTier(TIER_LOW, 1 days, 1 ether, true);
        vm.warp(block.timestamp + 1 days + 1);
        vm.expectRevert(
            abi.encodeWithSelector(DAOTreasuryExecutionEngine.NativeValueTooHigh.selector, 250 ether, 1 ether)
        );
        treasury.executePackage(id);
    }

    function test_DisabledTierAfterSchedulingBlocksExecution() public {
        bytes32 id = _approve(address(target), 0, "", TIER_LOW);
        treasury.configureTier(TIER_LOW, 1 days, 250 ether, false);
        vm.warp(block.timestamp + 1 days + 1);
        vm.expectRevert(abi.encodeWithSelector(DAOTreasuryExecutionEngine.TierDisabled.selector, TIER_LOW));
        treasury.executePackage(id);
    }

    // ------------------------------------------------------------------
    // Minimum tier delay + allowlist self-guard
    // ------------------------------------------------------------------

    function test_ZeroDelayTierReverts() public {
        vm.expectRevert(abi.encodeWithSelector(DAOTreasuryExecutionEngine.TierDelayTooShort.selector, 0, 1 hours));
        treasury.configureTier(TIER_LOW, 0, 1 ether, true);
    }

    function test_EnableAllowlistWithoutSelfListedReverts() public {
        vm.expectRevert(abi.encodeWithSelector(DAOTreasuryExecutionEngine.TargetNotAllowed.selector, address(treasury)));
        treasury.setTargetAllowlistEnabled(true);
    }

    // ------------------------------------------------------------------
    // dataHash retention + state getter + batch reads
    // ------------------------------------------------------------------

    function test_DataHashRetainedAfterExecution() public {
        bytes memory data = abi.encodeCall(FlagTarget.setFlag, (7));
        bytes32 id = _approve(address(target), 0, data, TIER_LOW);
        vm.warp(block.timestamp + 1 days + 1);
        treasury.executePackage(id);
        DAOTreasuryExecutionEngine.Package memory pkg = treasury.getPackage(id);
        assertEq(pkg.data.length, 0, "calldata wiped");
        assertEq(pkg.dataHash, keccak256(data), "hash retained for audit");
    }

    function test_PackageStateLifecycle() public {
        bytes32 id = _approve(address(target), 0, abi.encodeCall(FlagTarget.setFlag, (1)), TIER_LOW);
        assertEq(treasury.packageState(id), 0, "pending during quarantine");
        vm.warp(block.timestamp + 1 days + 1);
        assertEq(treasury.packageState(id), 1, "executable after quarantine");
        treasury.executePackage(id);
        assertEq(treasury.packageState(id), 2, "executed");
    }

    function test_PackageStateExpired() public {
        uint48 expiresAt = uint48(block.timestamp + 2 days);
        bytes32 id = treasury.approvePackage(address(target), 0, "", TIER_LOW, expiresAt, bytes32(0));
        vm.warp(expiresAt);
        assertEq(treasury.packageState(id), 4, "expired");
        treasury.closeExpiredPackage(id);
        assertEq(treasury.packageState(id), 3, "finalized as cancelled");
    }

    function test_BatchApproveExecuteAndSweep() public {
        DAOTreasuryExecutionEngine.PackageRequest[] memory reqs = new DAOTreasuryExecutionEngine.PackageRequest[](2);
        reqs[0] = DAOTreasuryExecutionEngine.PackageRequest({
            target: address(target),
            value: 0,
            data: abi.encodeCall(FlagTarget.setFlag, (11)),
            tier: TIER_LOW,
            expiresAt: uint48(0),
            predecessor: bytes32(0)
        });
        reqs[1] = DAOTreasuryExecutionEngine.PackageRequest({
            target: address(target),
            value: 0,
            data: abi.encodeCall(FlagTarget.setFlag, (22)),
            tier: TIER_LOW,
            expiresAt: uint48(block.timestamp + 10 days),
            predecessor: bytes32(0)
        });
        bytes32[] memory ids = treasury.approvePackages(reqs);
        assertEq(ids.length, 2);
        assertEq(treasury.getPackages(ids).length, 2);

        vm.warp(block.timestamp + 1 days + 1);
        bytes32[] memory execIds = new bytes32[](1);
        execIds[0] = ids[0];
        treasury.executePackages(execIds);
        assertEq(target.flag(), 11);

        // Second package expires; batch sweep finalizes it.
        vm.warp(block.timestamp + 10 days);
        bytes32[] memory sweepIds = new bytes32[](1);
        sweepIds[0] = ids[1];
        assertEq(treasury.closeExpiredPackages(sweepIds), 1);
        assertTrue(treasury.getPackage(ids[1]).cancelled);
    }

    // ------------------------------------------------------------------
    // Predecessor clearing
    // ------------------------------------------------------------------

    function test_ClearPredecessorUnbricksDependent() public {
        bytes32 first = _approve(address(target), 0, abi.encodeCall(FlagTarget.setFlag, (1)), TIER_LOW);
        bytes32 second =
            treasury.approvePackage(address(target), 0, abi.encodeCall(FlagTarget.setFlag, (2)), TIER_LOW, 0, first);
        treasury.cancelPackage(first); // governance cancel bricks `second`
        treasury.clearPredecessor(second);
        vm.warp(block.timestamp + 1 days + 1);
        treasury.executePackage(second);
        assertTrue(treasury.getPackage(second).executed);
    }

    // ------------------------------------------------------------------
    // Spend limiter
    // ------------------------------------------------------------------

    function test_SpendLimitBoundsOutflowPerWindow() public {
        deal(address(treasury), 10 ether);
        treasury.setSpendLimit(3 ether, 30 days);

        bytes32 id1 = treasury.approvePackage(
            address(target), 2 ether, abi.encodeCall(FlagTarget.setFlag, (1)), TIER_LOW, 0, bytes32(0)
        );
        bytes32 id2 = treasury.approvePackage(
            address(target), 2 ether, abi.encodeCall(FlagTarget.setFlag, (2)), TIER_LOW, 0, bytes32(0)
        );
        vm.warp(block.timestamp + 1 days + 1);

        treasury.executePackage(id1);
        assertEq(treasury.spentInWindow(), 2 ether);
        vm.expectRevert(
            abi.encodeWithSelector(DAOTreasuryExecutionEngine.SpendLimitExceeded.selector, 4 ether, 3 ether)
        );
        treasury.executePackage(id2);

        // Next window resets the budget.
        vm.warp(block.timestamp + 30 days);
        treasury.executePackage(id2);
        assertEq(address(treasury).balance, 6 ether);
    }

    function test_SpendLimitZeroWindowReverts() public {
        vm.expectRevert(DAOTreasuryExecutionEngine.InvalidSpendWindow.selector);
        treasury.setSpendLimit(1 ether, 0);
    }

    // ------------------------------------------------------------------
    // Direct-target ERC20 floor
    // ------------------------------------------------------------------

    function test_ERC20FloorEnforcedOnDirectTarget() public {
        spend.mint(address(treasury), 100e18);
        treasury.setERC20ReserveFloor(spend, 40e18);

        // Leaves 30 < 40 behind: must revert.
        bytes32 drain = treasury.approvePackage(
            address(spend), 0, abi.encodeCall(ERC20.transfer, (guardian, 70e18)), TIER_LOW, 0, bytes32(0)
        );
        vm.warp(block.timestamp + 1 days + 1);
        vm.expectRevert(abi.encodeWithSelector(DAOTreasuryExecutionEngine.ReserveFloorBreached.selector, 30e18, 40e18));
        treasury.executePackage(drain);

        // Leaves exactly 40: succeeds.
        bytes32 ok = treasury.approvePackage(
            address(spend), 0, abi.encodeCall(ERC20.transfer, (guardian, 60e18)), TIER_LOW, 0, bytes32(0)
        );
        vm.warp(block.timestamp + 1 days + 1);
        treasury.executePackage(ok);
        assertEq(spend.balanceOf(address(treasury)), 40e18);
    }

    // ------------------------------------------------------------------
    // Governor voting floors (via real proposals: OZ onlyGovernance requires
    // the proposal-execution whitelist)
    // ------------------------------------------------------------------

    function test_GovernorVotingFloors() public {
        DAOGovernanceToken token = new DAOGovernanceToken("T", "T", address(this), 1_000_000e18);
        address holder = makeAddr("holder");
        token.transfer(holder, 500_000e18);
        vm.prank(holder);
        token.delegate(holder);
        vm.prank(address(this));
        token.delegate(address(this));

        address[] memory noProposers = new address[](0);
        address[] memory openExecutors = new address[](1);
        openExecutors[0] = address(0);
        TimelockController timelock = new TimelockController(1 days, noProposers, openExecutors, address(this));

        EnterpriseDAO.GovernorConfig memory cfg = EnterpriseDAO.GovernorConfig({
            name: "G",
            token: IVotes(address(token)),
            timelock: timelock,
            votingDelayBlocks: 100,
            votingPeriodBlocks: 500,
            proposalThreshold: 1e18,
            quorumMinBps: 400,
            quorumMaxBps: 1000,
            quorumLowSupplyThreshold: 1,
            quorumHighSupplyThreshold: 2,
            minProposalThreshold: 1,
            maxProposalThreshold: type(uint256).max
        });
        EnterpriseDAO gov = new EnterpriseDAO(cfg);
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(gov));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(gov));
        vm.roll(block.number + 1);

        assertEq(gov.minimumVotingDelay(), 100);
        assertEq(gov.minimumVotingPeriod(), 500);

        // Lengthening the delay succeeds end-to-end.
        _govPassAndExecute(
            gov, timelock, holder, address(gov), abi.encodeCall(EnterpriseDAO.setVotingDelay, (200)), "lengthen delay"
        );
        assertEq(gov.votingDelay(), 200);

        // Shortening below deployment reverts at execution.
        _govVoteAndQueue(
            gov, timelock, holder, address(gov), abi.encodeCall(EnterpriseDAO.setVotingDelay, (50)), "shorten delay"
        );
        vm.expectRevert(abi.encodeWithSelector(EnterpriseDAO.GovernanceConfigOutOfBounds.selector, 50, 100));
        gov.execute(_t, _v, _c, _h);

        _govVoteAndQueue(
            gov, timelock, holder, address(gov), abi.encodeCall(EnterpriseDAO.setVotingPeriod, (100)), "shorten period"
        );
        vm.expectRevert(abi.encodeWithSelector(EnterpriseDAO.GovernanceConfigOutOfBounds.selector, 100, 500));
        gov.execute(_t, _v, _c, _h);
    }

    address[] internal _t;
    uint256[] internal _v;
    bytes[] internal _c;
    bytes32 internal _h;

    function _govVoteAndQueue(
        EnterpriseDAO gov,
        TimelockController,
        address holder,
        address callTarget,
        bytes memory callData,
        string memory description
    ) internal {
        _t = new address[](1);
        _v = new uint256[](1);
        _c = new bytes[](1);
        _t[0] = callTarget;
        _v[0] = 0;
        _c[0] = callData;
        _h = keccak256(bytes(description));
        vm.prank(holder);
        uint256 proposalId = gov.propose(_t, _v, _c, description);
        vm.roll(block.number + 201); // past voting delay (100 at deploy, 200 after lengthening)
        vm.prank(holder);
        gov.castVote(proposalId, 1);
        vm.roll(block.number + 501); // past voting period (500)
        gov.queue(_t, _v, _c, _h);
        vm.warp(block.timestamp + 1 days + 1); // past timelock delay
    }

    function _govPassAndExecute(
        EnterpriseDAO gov,
        TimelockController timelock,
        address holder,
        address callTarget,
        bytes memory callData,
        string memory description
    ) internal {
        _govVoteAndQueue(gov, timelock, holder, callTarget, callData, description);
        gov.execute(_t, _v, _c, _h);
    }
}
