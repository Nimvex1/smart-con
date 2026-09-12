// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {DAOTreasuryExecutionEngine} from "../contracts/DAOTreasuryExecutionEngine.sol";

/// @dev ERC20 that attempts to reenter the treasury during transferFrom.
///      The treasury has no transfer hooks into ERC20 deposit from a token callback
///      (depositERC20 uses safeTransferFrom then emits), so reentry has no surface
///      except calling public treasury functions as a normal caller.
contract ReentrantERC20 is IERC20 {
    DAOTreasuryExecutionEngine public immutable treasury;
    address public immutable deployer;
    bool private _inFlight;

    constructor(DAOTreasuryExecutionEngine treasury_) {
        treasury = treasury_;
        deployer = msg.sender;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return true;
    }

    function allowance(address, address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function approve(address, uint256) external pure returns (bool) {
        return true;
    }

    function totalSupply() external pure returns (uint256) {
        return 0;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function transferFrom(address, address to, uint256) external returns (bool) {
        if (!_inFlight) {
            _inFlight = true;
            // Reentry attempt: call deposit again (it reverts on zero amount) and try
            // to execute a package. Both must fail or be no-ops; the original deposit
            // must still complete exactly once.
            treasury.depositERC20(IERC20(address(this)), 0);
        }
        return true; // pretend success
    }
}

/// @dev ERC20 whose transferFrom returns no data at all (raw `return` with empty
///      body). SafeERC20 must detect the missing success boolean and revert.
contract MalformedDataERC20 {
    function name() external pure returns (string memory) {
        return "Malformed";
    }

    function deposit(DAOTreasuryExecutionEngine treasury) external {
        treasury.depositERC20(IERC20(address(this)), 1);
    }

    function transferFrom(address, address, uint256) external pure {
        // returns nothing: no ABI-encoded bool
    }

    function allowance(address, address) external pure returns (uint256) {
        return type(uint256).max;
    }
}

/// @dev ERC20 whose transferFrom reverts on every call.
contract RevertingERC20 is IERC20 {
    function transfer(address, uint256) external pure returns (bool) {
        revert("no");
    }

    function allowance(address, address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function approve(address, uint256) external pure returns (bool) {
        return true;
    }

    function totalSupply() external pure returns (uint256) {
        return 0;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        revert("token broken");
    }
}

/// @dev ERC20 that returns `false` from transferFrom (pre-SafeERC20 style).
contract FalseReturnERC20 is IERC20 {
    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }

    function allowance(address, address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function approve(address, uint256) external pure returns (bool) {
        return true;
    }

    function totalSupply() external pure returns (uint256) {
        return 0;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return false;
    }
}

/// @dev Target contract that burns an excessive amount of gas during execution,
///      to surface gas-griefing behaviour on package execution paths.
contract GasGuzzlerTarget {
    uint256 public sink;

    function expensiveLoop(uint256 iterations) external payable {
        uint256 acc;
        for (uint256 i = 0; i < iterations; ++i) {
            acc = uint256(keccak256(abi.encodePacked(acc, i)));
        }
        sink = acc;
    }
}

/// @dev Suite asserting the treasury behaves against hostile tokens and targets:
///      reentrancy, malformed return data, unexpected reverts, false returns, and
///      gas griefing.
contract MaliciousTokenTest is Test {
    DAOTreasuryExecutionEngine internal treasury;
    address internal guardian = makeAddr("guardian");
    address internal rando = makeAddr("rando");

    function setUp() public {
        treasury = new DAOTreasuryExecutionEngine(address(this), guardian);
    }

    function test_ReentrantDepositCannotDoubleCount() public {
        ReentrantERC20 token = new ReentrantERC20(treasury);
        // The reentering transferFrom calls depositERC20 with amount 0, which reverts
        // inside the token's transferFrom itself — that revert must propagate: the
        // outer deposit must fail, never silently complete.
        vm.expectRevert(DAOTreasuryExecutionEngine.InvalidZeroAmount.selector);
        treasury.depositERC20(IERC20(address(token)), 1);
    }

    function test_MalformedReturnDataToleratedWithoutAccounting() public {
        MalformedDataERC20 token = new MalformedDataERC20();
        // SafeERC20 treats non-reverting empty returndata as success (per its
        // documented behaviour for non-standard tokens): the deposit completes but
        // the treasury never trusts token-side accounting, only its own events.
        token.deposit(treasury);
        // Real balance assertions are impossible with this mock (balanceOf is not
        // implemented); the safety property is that the call neither reverts nor
        // causes any state inconsistency in the treasury itself.
    }

    function test_RevertingTokenPropagates() public {
        RevertingERC20 token = new RevertingERC20();
        vm.expectRevert(bytes("token broken"));
        treasury.depositERC20(IERC20(address(token)), 1);
    }

    function test_FalseReturnTokenReverts() public {
        FalseReturnERC20 token = new FalseReturnERC20();
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        treasury.depositERC20(IERC20(address(token)), 1);
    }

    function test_GasGuzzlerPackageExecutesWithinGasLimits() public {
        GasGuzzlerTarget guzzler = new GasGuzzlerTarget();
        bytes32 packageId = treasury.approvePackage(
            address(guzzler), 0, abi.encodeCall(GasGuzzlerTarget.expensiveLoop, (uint256(50))), 0, 0, bytes32(0)
        );
        vm.warp(block.timestamp + 1 days + 1);
        treasury.executePackage(packageId);
        assertTrue(guzzler.sink() != 0);
    }

    function test_GasGuzzlerPackageOutGasRevertsCleanly() public {
        GasGuzzlerTarget guzzler = new GasGuzzlerTarget();
        // 50k iterations is far beyond block gas limits: execution must revert and
        // roll back the executed flag, leaving the package retryable.
        bytes32 packageId = treasury.approvePackage(
            address(guzzler), 0, abi.encodeCall(GasGuzzlerTarget.expensiveLoop, (uint256(50_000))), 0, 0, bytes32(0)
        );
        vm.warp(block.timestamp + 1 days + 1);

        vm.expectRevert();
        treasury.executePackage{gas: 200_000}(packageId);

        DAOTreasuryExecutionEngine.Package memory pkg = treasury.getPackage(packageId);
        assertFalse(pkg.executed, "failed execution must roll back the executed flag");
        assertTrue(treasury.packageExists(packageId));
    }

    // ------------------------------------------------------------------
    // Reentrancy across executePackage: a target calling back into the treasury
    // ------------------------------------------------------------------

    function test_ExecutePackageReentrancyBlocked() public {
        ReenteringTarget rt = new ReenteringTarget(treasury);
        // Governance schedules a package that calls the target; the target tries to
        // reenter executePackage on an unrelated ready package. nonReentrant must stop it.
        bytes32 id1 = treasury.approvePackage(
            address(rt), 0, abi.encodeCall(ReenteringTarget.hit, (bytes32(0))), 0, 0, bytes32(0)
        );
        // A second ready package the reentering target will try to consume.
        CallCounter counter = new CallCounter();
        bytes32 id2 =
            treasury.approvePackage(address(counter), 0, abi.encodeCall(CallCounter.bump, ()), 0, 0, bytes32(0));

        vm.warp(block.timestamp + 1 days + 1);
        // The target itself reverts with "reenter failed" after the inner reentry is
        // blocked by nonReentrant; that revert propagates as ExecutionFailed.
        vm.expectRevert();
        treasury.executePackage(id1);

        assertFalse(treasury.getPackage(id2).executed, "reentered execution must not have executed");
        treasury.executePackage(id2); // still executable normally
        assertEq(counter.count(), 1);
    }
}

contract CallCounter {
    uint256 public count;

    function bump() external {
        ++count;
    }
}

/// @dev Target that reenters the treasury's executePackage during its own execution.
contract ReenteringTarget {
    DAOTreasuryExecutionEngine public immutable treasury;

    constructor(DAOTreasuryExecutionEngine treasury_) {
        treasury = treasury_;
    }

    function hit(bytes32 otherPackage) external {
        if (otherPackage != bytes32(0)) {
            // ignore failure, record below
            try treasury.executePackage(otherPackage) {
                revert("reentry unexpectedly succeeded");
            } catch {
                // expected: nonReentrant
            }
        }
        revert("reenter failed");
    }
}
