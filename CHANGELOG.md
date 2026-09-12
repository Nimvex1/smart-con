# Changelog

All notable changes to the Enterprise DAO Ecosystem. Format follows Keep a Changelog;
versioning is `MAJOR.MINOR.PATCH` on the audited `contracts/` surface.

## [Unreleased]

### Added
- `VestingVault`: cliff + linear vesting for contributor payouts (governance-created,
  allowance-funded, permissionless claims to beneficiary, revocable remainder).
- `DEPLOYER_ADMIN` env override in `script/Deploy.s.sol` for direct-to-multisig
  timelock admin at deployment.
- `COVERAGE.md` with per-file line/statement/branch/function coverage; CI uploads
  the `lcov.info` artifact on every push.
- `approvePackages` batch scheduling, `closeExpiredPackages` sweeper, `getPackages`
  batch reads, `packageState` lifecycle getter.
- Global native spend rate limiter (`setSpendLimit`) bounding outflow per window
  even under full governance capture.
- Direct-target on-chain ERC20 reserve-floor enforcement.

### Changed
- Dependencies (`lib/`) switched from vendored copies to pinned git submodules
  (OpenZeppelin `v5.1.0`, forge-std `v1.9.7`); CI checks out recursively.
- Execution revalidates allowlist, tier enabled-state and value caps, so tightening
  policy mid-incident stops pre-staged packages.
- Tier delays bounded to 1 hour – 365 days; package expiry capped at 365 days out.
- Voting delay/period floored at deployment values (lengthen-only).
- Allowlist enabling requires the treasury itself to be listed (self-brick guard).
- `DeployScript.t.sol` runs `Deploy.s.sol` end-to-end (script coverage 0% → 100%).

## [2.0.1] — Prior release

- Linear dynamic quorum governor, multi-tier quarantined treasury, time-bound
  guardian powers, full Foundry suite (unit, fuzz, invariant, malicious-token,
  governance-attack) and bootstrap deployment script.
