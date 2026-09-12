// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title VestingVault
/// @notice Minimal cliff + linear vesting for DAO contributor payouts.
///         Schedules are created by governance (the treasury timelock), funded with an
///         allowance-based pull, claimed to the beneficiary by anyone, and revocable
///         back to a governance-chosen refund address while unvested.
/// @dev Funded via treasury packages: one proposal approves the token allowance and
///      creates the schedule. No upgradeability, no fees, no owner keys.
contract VestingVault is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    struct Schedule {
        IERC20 token;
        address beneficiary;
        uint256 totalAmount;
        uint256 claimed;
        uint48 start;
        uint48 cliffDuration;
        uint48 duration;
        uint48 revokedAt;
        bool revocable;
        bool revoked;
    }

    uint256 public nextScheduleId = 1;
    mapping(uint256 scheduleId => Schedule schedule) private _schedules;

    event ScheduleCreated(
        uint256 indexed scheduleId,
        address indexed token,
        address indexed beneficiary,
        uint256 totalAmount,
        uint48 start,
        uint48 cliffDuration,
        uint48 duration,
        bool revocable
    );
    event Claimed(uint256 indexed scheduleId, address indexed beneficiary, uint256 amount);
    event ScheduleRevoked(uint256 indexed scheduleId, address indexed refundTo, uint256 unvested);

    error InvalidBeneficiary();
    error InvalidAmount();
    error InvalidDuration();
    error InvalidCliff();
    error ScheduleNotFound(uint256 scheduleId);
    error NothingVested(uint256 scheduleId);
    error Irrevocable(uint256 scheduleId);
    error AlreadyRevoked(uint256 scheduleId);

    constructor(address governance) {
        // Self-administered: role changes happen through governance-approved calls
        // targeting this contract, mirroring the treasury engine.
        _grantRole(DEFAULT_ADMIN_ROLE, address(this));
        _setRoleAdmin(GOVERNANCE_ROLE, GOVERNANCE_ROLE);
        _grantRole(GOVERNANCE_ROLE, governance);
    }

    /// @notice Create and fund a schedule in one call. The caller (governance timelock)
    ///         must have set a sufficient allowance for this vault beforehand.
    function createSchedule(
        IERC20 token,
        address beneficiary,
        uint256 amount,
        uint48 start,
        uint48 cliffDuration,
        uint48 duration,
        bool revocable
    ) external onlyRole(GOVERNANCE_ROLE) returns (uint256 scheduleId) {
        if (address(token) == address(0) || beneficiary == address(0)) revert InvalidBeneficiary();
        if (amount == 0) revert InvalidAmount();
        if (duration == 0) revert InvalidDuration();
        if (cliffDuration > duration) revert InvalidCliff();

        token.safeTransferFrom(msg.sender, address(this), amount);

        scheduleId = nextScheduleId++;
        _schedules[scheduleId] = Schedule({
            token: token,
            beneficiary: beneficiary,
            totalAmount: amount,
            claimed: 0,
            start: start,
            cliffDuration: cliffDuration,
            duration: duration,
            revokedAt: 0,
            revocable: revocable,
            revoked: false
        });

        emit ScheduleCreated(scheduleId, address(token), beneficiary, amount, start, cliffDuration, duration, revocable);
    }

    /// @notice Vested-but-unclaimed amount for a schedule at the current time.
    function claimable(uint256 scheduleId) external view returns (uint256) {
        Schedule storage s = _schedules[scheduleId];
        if (address(s.token) == address(0)) revert ScheduleNotFound(scheduleId);
        return _vested(s, _cappedNow(s)) - s.claimed;
    }

    /// @notice Total vested amount (including already claimed) at the current time.
    function vestedAmount(uint256 scheduleId) external view returns (uint256) {
        Schedule storage s = _schedules[scheduleId];
        if (address(s.token) == address(0)) revert ScheduleNotFound(scheduleId);
        return _vested(s, _cappedNow(s));
    }

    /// @notice Release vested tokens to the beneficiary. Permissionless: funds can
    ///         only ever flow to the recorded beneficiary.
    function claim(uint256 scheduleId) external nonReentrant {
        Schedule storage s = _schedules[scheduleId];
        if (address(s.token) == address(0)) revert ScheduleNotFound(scheduleId);

        uint256 amount = _vested(s, _cappedNow(s)) - s.claimed;
        if (amount == 0) revert NothingVested(scheduleId);
        s.claimed += amount;

        s.token.safeTransfer(s.beneficiary, amount);
        emit Claimed(scheduleId, s.beneficiary, amount);
    }

    /// @notice Governance reclaims the unvested remainder. Vested tokens stay claimable.
    function revoke(uint256 scheduleId, address refundTo) external onlyRole(GOVERNANCE_ROLE) nonReentrant {
        Schedule storage s = _schedules[scheduleId];
        if (address(s.token) == address(0)) revert ScheduleNotFound(scheduleId);
        if (!s.revocable) revert Irrevocable(scheduleId);
        if (s.revoked) revert AlreadyRevoked(scheduleId);
        if (refundTo == address(0)) revert InvalidBeneficiary();

        s.revoked = true;
        s.revokedAt = uint48(block.timestamp);

        uint256 unvested = s.totalAmount - _vested(s, s.revokedAt);
        if (unvested > 0) {
            s.token.safeTransfer(refundTo, unvested);
        }
        emit ScheduleRevoked(scheduleId, refundTo, unvested);
    }

    function getSchedule(uint256 scheduleId) external view returns (Schedule memory) {
        Schedule memory s = _schedules[scheduleId];
        if (address(s.token) == address(0)) revert ScheduleNotFound(scheduleId);
        return s;
    }

    /// @dev Vesting freezes at revocation; otherwise it accrues to now.
    function _cappedNow(Schedule storage s) private view returns (uint48) {
        if (s.revoked) return s.revokedAt;
        return uint48(block.timestamp);
    }

    /// @dev Cliff then linear: 0 before start + cliff, total after start + duration.
    function _vested(Schedule storage s, uint48 at) private view returns (uint256) {
        if (at < s.start + s.cliffDuration) return 0;
        if (at >= s.start + s.duration) return s.totalAmount;
        return (s.totalAmount * (at - s.start)) / s.duration;
    }
}
