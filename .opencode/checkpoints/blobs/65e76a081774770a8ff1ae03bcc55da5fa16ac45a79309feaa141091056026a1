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
/// 3.  Deploy `DAOTreasuryExecutionEngine(timelock, securityGuardian)` so the timelock
///     receives GOVERNANCE_ROLE and the guardian receives GUARDIAN_ROLE.
/// 4.  Deploy `EnterpriseDAO` with the `GovernorConfig` struct (token, timelock, voting
///     parameters, dynamic quorum bounds and proposal-threshold bounds).
/// 5.  Grant the Governor on the timelock:
///       PROPOSER_ROLE
///       CANCELLER_ROLE
/// 6.  Verify the Treasury GOVERNANCE_ROLE points only to the TimelockController, and
///     that the Governor's `_executor()` is exactly the TimelockController.
/// 7.  Move treasury assets into the treasury according to policy.
/// 8.  Verify the trust topology:
///     Token holders -> Governor -> TimelockController -> TreasuryExecutionEngine
///     and that guardian cancellation is only possible during each package's quarantine
///     window (before `executeAfter`), while unpause remains governance-only.
/// 9.  Renounce the deployer's temporary timelock admin rights
///     (`renounceRole(DEFAULT_ADMIN_ROLE, deployer)`). This is the moment governance
///     becomes self-sovereign.
/// 10. Before production funding, verify role membership, voting clock, quorum ramp,
///     tier delays and caps, pause/unpause split, and guardian cancellation windows.
///
/// IMPORTANT: In production, the securityGuardian should generally be an audited
/// multisig/security council rather than a single EOA, and bootstrap token distribution
/// should avoid concentrating > 50% of voting power in one entity before the first vote.
contract DAODeploymentNotes {}
