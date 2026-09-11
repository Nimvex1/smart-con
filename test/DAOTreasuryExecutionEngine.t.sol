// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {DAOTreasuryExecutionEngine} from "../contracts/DAOTreasuryExecutionEngine.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockERC721 is ERC721 {
    uint256 private _nextId;

    constructor() ERC721("Mock721", "M721") {}

    function mint(address to) external returns (uint256 id) {
        id = _nextId++;
        _mint(to, id);
    }
}

contract MockERC1155 is ERC1155 {
    constructor() ERC1155("https://example.com/{id}.json") {}

    function mint(address to, uint256 id, uint256 amount) external {
        _mint(to, id, amount, "");
    }
}

contract CallTarget {
    uint256 public flag;
    uint256 public lastNativeReceived;

    function setFlag(uint256 v) external payable {
        flag = v;
        lastNativeReceived = msg.value;
    }

    receive() external payable {
        lastNativeReceived = msg.value;
    }
}

contract RevertingTarget {
    function boom() external pure {
        revert("boom");
    }
}

contract DAOTreasuryExecutionEngineTest is Test {
    DAOTreasuryExecutionEngine internal treasury;
    CallTarget internal target;
    RevertingTarget internal revertingTarget;
    MockERC20 internal mock20;
    MockERC721 internal mock721;
    MockERC1155 internal mock1155;

    // Tier ids mirrored locally: contract-type-name constant access is not valid
    // Solidity, so the tests alias the treasury's tier ids here.
    uint8 internal constant TIER_LOW = 0;
    uint8 internal constant TIER_MEDIUM = 1;
    uint8 internal constant TIER_HIGH = 2;
    uint8 internal constant TIER_CRITICAL = 3;

    // The test contract impersonates the timelock (GOVERNANCE_ROLE).
    address internal guardian = makeAddr("guardian");
    address internal depositor = makeAddr("depositor");
    address internal rando = makeAddr("rando");

    function setUp() public {
        treasury = new DAOTreasuryExecutionEngine(address(this), guardian);
        target = new CallTarget();
        revertingTarget = new RevertingTarget();
        mock20 = new MockERC20();
        mock721 = new MockERC721();
        mock1155 = new MockERC1155();
    }

    function _approveFlagPackage(uint8 tier, uint256 flagValue) internal returns (bytes32 packageId) {
        (packageId,) = _approvePackage(address(target), 0, abi.encodeCall(CallTarget.setFlag, (flagValue)), tier);
    }

    function _approvePackage(address target_, uint256 value, bytes memory data, uint8 tier)
        internal
        returns (bytes32 packageId, uint48 executeAfter)
    {
        (uint48 tierDelay,,) = treasury.tierConfig(tier);
        executeAfter = uint48(block.timestamp + tierDelay);
        vm.expectEmit(true, true, true, true, address(treasury));
        emit DAOTreasuryExecutionEngine.PackageApproved(
            packageIdFor(target_, value, data, tier),
            target_,
            value,
            tier,
            treasury.nextPackageNonce(),
            executeAfter,
            keccak256(data)
        );
        packageId = treasury.approvePackage(target_, value, data, tier);
    }

    function packageIdFor(address target_, uint256 value, bytes memory data, uint8 tier)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(address(treasury), target_, value, keccak256(data), tier, treasury.nextPackageNonce())
        );
    }

    // ------------------------------------------------------------------
    // Deposits
    // ------------------------------------------------------------------

    function test_NativeDepositEmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(treasury));
        emit DAOTreasuryExecutionEngine.NativeDeposited(address(this), 1 ether);
        (bool ok,) = address(treasury).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(treasury.ethBalance(), 1 ether);
    }

    function test_DepositERC20() public {
        mock20.mint(depositor, 100e18);
        vm.startPrank(depositor);
        mock20.approve(address(treasury), 100e18);
        treasury.depositERC20(mock20, 100e18);
        vm.stopPrank();
        assertEq(mock20.balanceOf(address(treasury)), 100e18);
        assertEq(treasury.erc20Balance(mock20), 100e18);
    }

    function test_DepositERC20ZeroAmountReverts() public {
        vm.expectRevert(DAOTreasuryExecutionEngine.InvalidZeroAmount.selector);
        treasury.depositERC20(mock20, 0);
    }

    function test_DepositERC721() public {
        uint256 tokenId = mock721.mint(depositor);
        vm.startPrank(depositor);
        mock721.setApprovalForAll(address(treasury), true);
        treasury.depositERC721(mock721, tokenId);
        vm.stopPrank();
        assertEq(mock721.ownerOf(tokenId), address(treasury));
    }

    function test_DepositERC1155() public {
        mock1155.mint(depositor, 1, 100);
        vm.startPrank(depositor);
        mock1155.setApprovalForAll(address(treasury), true);
        treasury.depositERC1155(mock1155, 1, 100, "");
        vm.stopPrank();
        assertEq(mock1155.balanceOf(address(treasury), 1), 100);
    }

    // ------------------------------------------------------------------
    // Package scheduling and execution
    // ------------------------------------------------------------------

    function test_ApproveAndExecutePackage() public {
        bytes32 packageId = _approveFlagPackage(TIER_LOW, 42);

        vm.warp(block.timestamp + 1 days + 1);

        vm.expectEmit(true, true, false, true, address(treasury));
        emit DAOTreasuryExecutionEngine.PackageExecuted(packageId, address(target), 0, "");
        treasury.executePackage(packageId);

        assertEq(target.flag(), 42, "package execution must reach the target");

        DAOTreasuryExecutionEngine.Package memory pkg = treasury.getPackage(packageId);
        assertTrue(pkg.executed, "package must be marked executed");
        assertFalse(pkg.cancelled, "package must not be cancelled");
        assertEq(pkg.data.length, 0, "calldata must be wiped after execution");
        assertEq(pkg.tier, TIER_LOW);
    }

    function test_ExecuteBeforeDelayReverts() public {
        bytes32 packageId = _approveFlagPackage(TIER_MEDIUM, 1);
        vm.warp(block.timestamp + 1 days); // 3-day tier, only 1 day elapsed

        vm.expectRevert(
            abi.encodeWithSelector(
                DAOTreasuryExecutionEngine.PackageNotReady.selector, packageId, uint48(vm.getBlockTimestamp() + 2 days)
            )
        );
        treasury.executePackage(packageId);
    }

    function test_ExecuteUnknownPackageReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(DAOTreasuryExecutionEngine.PackageNotFound.selector, bytes32(uint256(0xdead)))
        );
        treasury.executePackage(bytes32(uint256(0xdead)));
    }

    function test_ReExecuteReverts() public {
        bytes32 packageId = _approveFlagPackage(TIER_LOW, 1);
        vm.warp(block.timestamp + 1 days + 1);
        treasury.executePackage(packageId);

        vm.expectRevert(abi.encodeWithSelector(DAOTreasuryExecutionEngine.PackageAlreadyFinalized.selector, packageId));
        treasury.executePackage(packageId);
    }

    function test_ExecuteRejectsAttachedValue() public {
        bytes32 packageId = _approveFlagPackage(TIER_LOW, 1);
        vm.warp(block.timestamp + 1 days + 1);

        vm.expectRevert(abi.encodeWithSelector(DAOTreasuryExecutionEngine.UnexpectedMsgValue.selector, 1 ether));
        treasury.executePackage{value: 1 ether}(packageId);
    }

    function test_ApproveRejectsValueAboveTierCap() public {
        vm.expectRevert(
            abi.encodeWithSelector(DAOTreasuryExecutionEngine.NativeValueTooHigh.selector, 251 ether, 250 ether)
        );
        treasury.approvePackage(address(target), 251 ether, "", TIER_LOW);

        vm.expectRevert(
            abi.encodeWithSelector(DAOTreasuryExecutionEngine.NativeValueTooHigh.selector, 6 ether, 5 ether)
        );
        treasury.approvePackage(address(target), 6 ether, "", TIER_CRITICAL);
    }

    function test_ApproveRejectsInvalidTierAndDisabledTier() public {
        vm.expectRevert(abi.encodeWithSelector(DAOTreasuryExecutionEngine.InvalidTier.selector, 4));
        treasury.approvePackage(address(target), 0, "", 4);

        treasury.configureTier(TIER_HIGH, 7 days, 25 ether, false);
        vm.expectRevert(abi.encodeWithSelector(DAOTreasuryExecutionEngine.TierDisabled.selector, TIER_HIGH));
        treasury.approvePackage(address(target), 0, "", TIER_HIGH);
    }

    function test_ExecuteForwardsNativeValue() public {
        deal(address(treasury), 5 ether);

        (bytes32 packageId,) = _approvePackage(address(target), 0.5 ether, "", TIER_LOW);
        vm.warp(block.timestamp + 1 days + 1);

        treasury.executePackage(packageId);

        assertEq(target.lastNativeReceived(), 0.5 ether, "treasury must forward its own ETH");
        assertEq(treasury.ethBalance(), 4.5 ether, "treasury balance must decrease");
    }

    function test_FailingTargetPropagatesAndRollsBack() public {
        (bytes32 packageId,) =
            _approvePackage(address(revertingTarget), 0, abi.encodeCall(RevertingTarget.boom, ()), TIER_LOW);
        vm.warp(block.timestamp + 1 days + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                DAOTreasuryExecutionEngine.ExecutionFailed.selector,
                packageId,
                abi.encodeWithSignature("Error(string)", "boom")
            )
        );
        treasury.executePackage(packageId);

        DAOTreasuryExecutionEngine.Package memory pkg = treasury.getPackage(packageId);
        assertFalse(pkg.executed, "failed execution must roll back the executed flag");
    }

    function test_BatchExecutePackages() public {
        bytes32 id1 = _approveFlagPackage(TIER_LOW, 1);
        bytes32 id2 = _approveFlagPackage(TIER_LOW, 2);
        bytes32 id3 = _approveFlagPackage(TIER_LOW, 3);

        vm.warp(block.timestamp + 1 days + 1);

        bytes32[] memory packageIds = new bytes32[](3);
        packageIds[0] = id1;
        packageIds[1] = id2;
        packageIds[2] = id3;

        vm.expectEmit(false, false, false, true, address(treasury));
        emit DAOTreasuryExecutionEngine.PackagesBatchExecuted(3);
        bytes[] memory results = treasury.executePackages(packageIds);

        assertEq(results.length, 3);
        assertEq(target.flag(), 3, "last package wins on shared state");
        assertTrue(treasury.getPackage(id1).executed);
        assertTrue(treasury.getPackage(id2).executed);
        assertTrue(treasury.getPackage(id3).executed);
    }

    function test_PackageHashMatchesEmittedId() public {
        bytes memory data = abi.encodeCall(CallTarget.setFlag, (uint256(99)));
        bytes32 expected = treasury.packageHash(address(target), 0, data, TIER_LOW, 1);
        (bytes32 packageId,) = _approvePackage(address(target), 0, data, TIER_LOW);
        assertEq(packageId, expected, "package id must commit to all package fields");
    }

    // ------------------------------------------------------------------
    // Cancellation: time-bound guardian, unlimited governance
    // ------------------------------------------------------------------

    function test_GuardianCancelDuringQuarantine() public {
        bytes32 packageId = _approveFlagPackage(TIER_LOW, 1);

        vm.expectEmit(true, true, false, true, address(treasury));
        emit DAOTreasuryExecutionEngine.PackageCancelled(packageId, guardian);
        vm.prank(guardian);
        treasury.cancelPackage(packageId);

        assertTrue(treasury.getPackage(packageId).cancelled);

        vm.warp(block.timestamp + 1 days + 1);
        vm.expectRevert(abi.encodeWithSelector(DAOTreasuryExecutionEngine.PackageAlreadyFinalized.selector, packageId));
        treasury.executePackage(packageId);
    }

    function test_GuardianCancelWindowClosedAfterQuarantine() public {
        bytes32 packageId = _approveFlagPackage(TIER_LOW, 1);

        vm.warp(block.timestamp + 1 days + 1); // quarantine elapsed

        vm.expectRevert(
            abi.encodeWithSelector(
                DAOTreasuryExecutionEngine.GuardianCancelWindowClosed.selector,
                packageId,
                uint48(vm.getBlockTimestamp() - 1)
            )
        );
        vm.prank(guardian);
        treasury.cancelPackage(packageId);
    }

    function test_GovernanceCancelAnytime() public {
        bytes32 packageId = _approveFlagPackage(TIER_LOW, 1);

        vm.warp(block.timestamp + 30 days); // long past the window

        treasury.cancelPackage(packageId);
        assertTrue(treasury.getPackage(packageId).cancelled, "governance cancels without a window");
    }

    function test_UnauthorizedCancelReverts() public {
        bytes32 packageId = _approveFlagPackage(TIER_LOW, 1);

        vm.expectRevert(
            abi.encodeWithSelector(DAOTreasuryExecutionEngine.CallerNotGovernanceOrGuardian.selector, rando)
        );
        vm.prank(rando);
        treasury.cancelPackage(packageId);
    }

    // ------------------------------------------------------------------
    // Access control
    // ------------------------------------------------------------------

    function test_ApproveOnlyGovernance() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, rando, treasury.GOVERNANCE_ROLE()
            )
        );
        vm.prank(rando);
        treasury.approvePackage(address(target), 0, "", TIER_LOW);
    }

    function test_PauseBlocksExecutionAndDeposits() public {
        bytes32 packageId = _approveFlagPackage(TIER_LOW, 1);
        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(guardian);
        treasury.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        treasury.executePackage(packageId);

        vm.expectRevert(Pausable.EnforcedPause.selector);
        treasury.depositERC20(mock20, 1e18);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, guardian, treasury.GOVERNANCE_ROLE()
            )
        );
        vm.prank(guardian);
        treasury.unpause();

        treasury.unpause(); // governance unpause
        treasury.executePackage(packageId);
        assertEq(target.flag(), 1, "execution resumes after governance unpause");
    }

    function test_PauseRequiresGuardian() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, rando, treasury.GUARDIAN_ROLE()
            )
        );
        vm.prank(rando);
        treasury.pause();
    }

    function test_TierReconfigureGovernanceOnly() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, guardian, treasury.GOVERNANCE_ROLE()
            )
        );
        vm.prank(guardian);
        treasury.configureTier(TIER_LOW, 0, 1 ether, true);

        vm.expectEmit(true, false, false, true, address(treasury));
        emit DAOTreasuryExecutionEngine.TierConfigured(TIER_LOW, 2 days, 10 ether, true);
        treasury.configureTier(TIER_LOW, 2 days, 10 ether, true);

        (uint48 tierDelay, uint256 tierCap, bool tierEnabled) = treasury.tierConfig(TIER_LOW);
        assertEq(tierDelay, 2 days);
        assertEq(tierCap, 10 ether);
        assertTrue(tierEnabled);

        vm.expectRevert(
            abi.encodeWithSelector(DAOTreasuryExecutionEngine.NativeValueTooHigh.selector, 11 ether, 10 ether)
        );
        treasury.approvePackage(address(target), 11 ether, "", TIER_LOW);
    }

    function test_TierDelayUpperBound() public {
        vm.expectRevert(
            abi.encodeWithSelector(DAOTreasuryExecutionEngine.TierDelayTooLong.selector, 366 days, 365 days)
        );
        treasury.configureTier(TIER_LOW, 366 days, 1 ether, true);
    }
}
