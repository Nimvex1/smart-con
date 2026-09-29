// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Deployment sequencing reference. Not intended for deployment itself.
/// @dev The executable version of this sequence lives in `script/Deploy.s.sol`.
///      Read this as the checklist of WHAT must be true before the system is funded.
///
/// 1.  Deploy `DAOGovernanceToken` with the bootstrap recipient (e.g. a multisig that
///     will distribute tokens to the community). Supply is fixed forever after this.
/// 2.  Deploy `TimelockController` with a temporary deployer admin, no proposers, and
///     EXECUTOR_ROLE granted to `address(0)` for permissionless timelock execution.
/// 3.  Deploy `DAOTreasuryExecutionEngine(timelock, securityGuardian, riskLimiter,
///     minTierDelay)` so the timelock receives GOVERNANCE_ROLE, the guardian receives
///     GUARDIAN_ROLE, and the risk limiter receives RISK_LIMITER_ROLE. The risk limiter
///     MUST be a key independent of the governor and of the guardian: it holds the sole
///     authority to loosen value caps, the allowlist and the native reserve floor, and
///     `minTierDelay` is the immutable floor beneath every tier delay. Putting the
///     limiter under the same control as the governor makes all of it decorative.
/// 4.  Deploy `EnterpriseDAO` with the `GovernorConfig` struct (token, timelock, voting
///     parameters, dynamic quorum bounds and proposal-threshold bounds).
/// 5.  Grant the Governor on the timelock:
///       PROPOSER_ROLE
///       CANCELLER_ROLE
/// 6.  Verify the Treasury GOVERNANCE_ROLE points only to the TimelockController, that
///     the Governor's `_executor()` is exactly the TimelockController, and that the
///     RISK_LIMITER_ROLE holder is none of {timelock, governor, guardian}.
///     `script/Deploy.s.sol` asserts all of this and reverts the deployment otherwise.
/// 7.  Move treasury assets into the treasury according to policy.
/// 8.  Verify the trust topology:
///     Token holders -> Governor -> TimelockController -> TreasuryExecutionEngine
///     TreasuryExecutionEngine <- Security council (RISK_LIMITER_ROLE, risk limits only)
///     TreasuryExecutionEngine <- Guardian (GUARDIAN_ROLE)
///     and that guardian cancellation is only possible during each package's quarantine
///     window (before `executeAfter`), while unpause remains governance-only.
/// 9.  Renounce the deployer's temporary timelock admin rights
///     (`renounceRole(DEFAULT_ADMIN_ROLE, deployer)`). This is the moment governance
///     becomes self-sovereign.
/// 10. Before production funding, verify role membership, voting clock, quorum ramp,
///     tier delays and caps, pause/unpause split, guardian cancellation windows, and the
///     `minTierDelay` floor.
///
/// IMPORTANT: In production, the securityGuardian should generally be an audited
/// multisig/security council rather than a single EOA, and bootstrap token distribution
/// should avoid concentrating > 50% of voting power in one entity before the first vote.
/// The riskLimiter should likewise be an audited council, and must not share signers
/// with the guardian or with whoever can reach the timelock.
contract DAODeploymentNotes {}
