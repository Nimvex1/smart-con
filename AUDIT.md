# Security Audit Report — smart-con (Enterprise DAO Ecosystem)

**Date:** 2025-02-14
**Auditor:** Automated static review (OpenCode agent)
**Scope:** `contracts/DAOGovernanceToken.sol`, `contracts/EnterpriseDAO.sol`,
`contracts/DAOTreasuryExecutionEngine.sol`, `script/Deploy.s.sol` (~768 lines of Solidity)
**Method:** Full manual read of all in-scope files, cross-checked against `SECURITY.md`
claims. Static analysis only — no Foundry runtime was available to the auditor, so
`forge test` / fuzz / invariant suites were **not** re-run; CI history is the evidence
for those.
**Commit:** e535b69 (main)

## Summary

| Severity | Count |
| --- | --- |
| Critical | 0 |
| High | 0 |
| Medium | 3 |
| Low | 4 |
| Info | 3 |

No fund-theft paths were found. All findings are governance-action footguns,
doc/code mismatches, or dead code. The implemented security model (time-bound
guardian powers, snapshot-safe dynamic quorum, tiered execution delays, CEI +
reentrancy guards) matches `SECURITY.md` in every verified claim.

## Medium

### M1. `MAX_PACKAGE_EXPIRY` is declared but never enforced

**Location:** `contracts/DAOTreasuryExecutionEngine.sol:43`

The constant's NatSpec promises a package "must be executable (executeAfter must be
within this window after approval) so governance cannot park a package for a decade
ahead." Grep confirms the constant is referenced exactly once — its own declaration.
`approvePackage` accepts any `expiresAt`, including far-future values and `0`
(no expiry).

Governance-only action, so not directly exploitable, but a documented control that
does not exist is a defect in itself.

**Recommendation:** enforce `expiresAt <= block.timestamp + MAX_PACKAGE_EXPIRY` in
`approvePackage` (when `expiresAt != 0`), or delete the constant and its comment.

### M2. ERC20 reserve floors are stored but never enforced on-chain

**Location:** `contracts/DAOTreasuryExecutionEngine.sol:82, 411`

`setERC20ReserveFloor` writes `erc20ReserveFloors[token]` and emits an event, implying
enforcement. Nothing in `_executePackage` reads the mapping. The function's own
comment admits enforcement is off-chain monitoring only. An operator reading the
public API could reasonably believe a floor is an on-chain control.

On-chain enforcement against arbitrary calldata is genuinely hard — that is why it is
missing — but the API surface is misleading.

**Recommendation:** rename the setter (e.g. `setERC20ReserveFloorReference`) and/or
document the informational status in the NatSpec prominently, or remove the feature
entirely and keep the off-chain monitoring note in `SECURITY.md`.

### M3. Deployer retains timelock `DEFAULT_ADMIN_ROLE` after deployment

**Location:** `script/Deploy.s.sol:154–161`

The deploy script asserts the full post-deployment wiring but leaves renouncing the
deployer admin role as a printed manual step. A forgotten renunciation leaves a
single key able to grant itself proposer rights — full governance capture.

**Recommendation:** renounce in-script after the assertion block, or ship a
`Renounce.s.sol` verification script that reverts if the deployer still holds the role.

## Low

### L1. Predecessor comment claims a check that does not exist

**Location:** `contracts/DAOTreasuryExecutionEngine.sol:221–227`

Comment: a predecessor must "not already be finalized as cancelled." Code only checks
existence (`pred.target == address(0)`). A package can be approved with an
already-cancelled predecessor, creating a permanently unexecutable package.
Governance can cancel it manually, so this is self-inflicted only.

**Recommendation:** add `if (pred.cancelled) revert PredecessorCancelled(...)` or
fix the comment.

### L2. Dead code

**Location:** `contracts/DAOTreasuryExecutionEngine.sol:84–92, 226`

- `PackageApproved` (V1) event is declared but never emitted (superseded by
  `PackageApprovedV2`).
- The `PredecessorCycle` guard at line 226 is unreachable (self-labeled "unreachable,
  guard") — `predecessor != bytes32(0)` is already checked before it.

**Recommendation:** delete both.

### L3. Stuck-package state leak

A successor package with `expiresAt = 0` whose predecessor is cancelled can never
execute and never be closed via `closeExpiredPackage` — only governance
`cancelPackage` can clean it.

**Recommendation:** allow `closeExpiredPackage` to also close packages whose
predecessor is cancelled.

### L4. `depositERC1155` accepts `amount == 0`

**Location:** `contracts/DAOTreasuryExecutionEngine.sol:184`

Unlike `depositERC20`, there is no zero-amount check. Harmless (event spam only).

**Recommendation:** add `if (amount == 0) revert InvalidZeroAmount();`.

## Info

- `closeExpiredPackage` reuses `PackageNotReady` for the "not yet expired" case —
  confusing error semantics for indexers.
- Deposits are `whenNotPaused`, so a guardian pause blocks inbound funds too. This is
  a documented DoS tradeoff, but inbound deposits are not a risk vector; consider
  allowing them while paused.
- Block-based voting clock (ERC-6372 default) — documented and consistent with the
  token's checkpointing setup.

## Verified sound

The following claims were verified directly in code:

- **Checks-effects-interactions in `_executePackage`:** `executed = true` is set
  before the external call; both execution entry points carry `nonReentrant`.
- **Snapshot-safe quorum:** `quorum()` reads `getPastTotalSupply(timepoint)` —
  flash-loan resistant; matches the adversarial test suite's coverage.
- **Time-bound guardian powers:** guardian cancellation window closes at
  `executeAfter`; `unpause` is governance-only. Code matches `SECURITY.md` exactly.
- **Package identity:** `packageId` binds `address(this)` + strictly increasing
  nonce — no replay, no collision.
- **Token supply:** minted exactly once in the constructor; no owner, no mint path.
- **Role topology:** treasury is self-administered; governance manages both
  GOVERNANCE_ROLE and GUARDIAN_ROLE membership.

## Verdict

The security design is real and the implementation matches its threat model almost
everywhere. The findings are documentation/code mismatches and one unenforced
constant — the classic gap between self-authored specs and implementation. All three
Mediums are cheap fixes. **Not yet audit-grade for mainnet funds, but close — fix
M1–M3, then obtain external review.**
