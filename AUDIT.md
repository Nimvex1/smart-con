# Security Audit Report — smart-con (Enterprise DAO Ecosystem)

**Date:** 2026-09-29
**Scope:** `contracts/DAOGovernanceToken.sol`, `contracts/EnterpriseDAO.sol`,
`contracts/DAOTreasuryExecutionEngine.sol`, `contracts/DAODeploymentNotes.sol`,
`script/Deploy.s.sol` (~830 lines of Solidity)
**Stack:** Solidity 0.8.24, Foundry, OpenZeppelin **5.1.0**. No proxy, no upgrade
path, no oracle, no external protocol dependency.
**Method:** Full manual read of every in-scope file, cross-checked line by line
against the claims in `SECURITY.md`, then each candidate finding validated with a
runnable Foundry test. Evidence in `test/AuditPoC.t.sol`.
**Status of all findings below:** fixed in this commit. Each fix has a regression
test that fails against the pre-fix contract.

## Summary

| Severity | Confirmed | Fixed |
|---|---|---|
| Critical | 0 | 0 |
| High | 0 | 0 |
| Medium | 1 | 1 |
| Low | 2 | 2 |
| Info/observation | 4 | 4 |

No unprivileged attack path to fund loss was found, before or after the fixes.

### Corrections to the previous report (2025-02-14)

This file previously contained a self-authored review. Two of its claims did not
hold and are retracted:

- **"L4 — `depositERC1155` accepts `amount == 0`" was false.** The zero-amount guard
  was present at `DAOTreasuryExecutionEngine.sol:188`. There was never a missing check.
- Its stated scope, **commit `e535b69`**, is real and is an ancestor of `main`
  (`e535b69` → `a21e622`, which added the report). The previous review's scope was
  therefore correctly pinned. It is worth recording *how* that was re-established:
  the working copy originally shipped with no `.git` directory at all, so its identity
  could not be confirmed from the tree itself and the commit reference had to be
  re-verified against the remote after `git init` + `git fetch`. A review performed
  on a tree with no version control is not reproducible, whatever it claims.

Its M1 (`MAX_PACKAGE_EXPIRY` unenforced), M2 (ERC20 floors not enforced), L1/L3
(predecessor stranding) and L2 (dead code) were independently re-derived and are
correct. **The previous review missed M1 below, which was the only finding that
mattered.**

---

## [MEDIUM] Risk limits were governance-exclusive, so they constrained nothing

**Location** `DAOTreasuryExecutionEngine.sol:374` (`configureTier`), `:387`, `:393`,
`:401`, `:218` (`executeAfter` derivation), `:451` (`_configureTier`)
**Contradicted claim** `SECURITY.md` §3 and §4 (pre-fix): *"the delay ladder is the
last line of defense. Tiers cap native value per package (5–250 ETH), and the
destination allowlist + reserve floors can be pre-configured to bound the blast
radius even under full capture."*

**Summary.** Every control that bounds the blast radius of a hostile governor — the
tier delay ladder, the per-tier value caps, the destination allowlist and the native
reserve floor — was `onlyRole(GOVERNANCE_ROLE)`. A control the constrained party can
relax constrains nothing. A single `TimelockController.executeBatch` could dismantle
all four and drain the treasury in one transaction with zero quarantine.

**Root cause.** `executeAfter` was derived from the mutable `tierConfig[tier].delay`,
and `_configureTier` enforced only an *upper* bound. `delay = 0` and
`maxNativeValue = type(uint256).max` were both legal.

**Proof (pre-fix).** Five calls in one batch — `configureTier(tier, 0, uint256.max, true)`,
`setTargetAllowlistEnabled(false)`, `setNativeReserveFloor(0)`,
`setTargetAllowed(target, false)`, `approvePackage(target, 1000 ether, "", tier, 0, 0)` —
drained 1000/1000 ETH in the same block, from a starting configuration of a 30-day
delay, a 1 ETH cap, the allowlist enabled and a 900 ETH floor.

**Impact.** Full native balance moves after `voting period + timelock minDelay`
(≈3.5d + 2d) instead of `+ minTierDelay..14 days`. Combined with the unrenounced
deployer scenario the doc itself modelled, one compromised key went from ~16 days to
full drain down to ~2 days.

**Fix.** Two independent mechanisms, so that neither key alone is sufficient:

1. `minTierDelay` is `immutable`, non-zero, and enforced in `_configureTier`. No
   account — not governance, not the limiter, not the treasury's own self-administered
   root — can set a tier delay below it. This is the unconditional last line of defence.
2. Authority over risk limits is **split, not stacked**. Loosening (delay decrease
   within the floor, cap increase, tier re-enable, allowlist disable/removal, native
   floor decrease) requires `RISK_LIMITER_ROLE`; tightening requires
   `GOVERNANCE_ROLE`. Compromising governance alone can schedule packages but cannot
   widen a single limit. Compromising the limiter alone can widen limits but cannot
   schedule, execute, pause or unpause. Both are required to remove the constraints,
   and even then the delay floor holds.

**Deliberate deviation from the report's own recommendation.** The report suggested a
nested `TimelockController` owned by a security council. A second role on the same
contract was chosen instead: it gives the same key-separation guarantee with one fewer
contract and one fewer deployment step. A first attempt stacked `onlyRole(GOVERNANCE_ROLE)`
with a limiter check, which was rejected during implementation because no single account
can then ever satisfy both — the loosening path would have been permanently dead.

**Regression tests** `test_M1_GovernanceAloneCannotLoosenAnyRiskLimit`,
`test_M1_LimiterCanLoosenButCannotSchedule`, `test_M1_GovernanceAloneCanTighten`,
`test_M1_DelayFloorHoldsForEveryCaller`, `test_M1_ZeroMinTierDelayRejectedAtConstruction`,
`test_M1_StricterFloorLiftsShippedDefaults`,
`test_CapturedGovernorCannotLoosenRiskLimits`,
`test_RiskLimiterIsIndependentOfGovernorAndGuardian`, plus
`test_TierDelayLowerBoundIsImmutable`.

**Residual risk, stated plainly.** This does not survive *simultaneous* compromise of
governance and the risk limiter: an attacker holding both can raise the caps to
unbounded and lift the allowlist, then drain after `minTierDelay`. That is not
preventable on-chain. The mitigation is operational — independent multisigs with
disjoint signers — and `script/Deploy.s.sol` reverts the deployment if the roles are
stacked or if the limiter collides with the guardian.

**Confidence:** High — mechanically demonstrated pre-fix and mechanically negated
post-fix.

---

## [LOW] `MAX_PACKAGE_EXPIRY` was declared but never enforced

**Location** `DAOTreasuryExecutionEngine.sol:40-43` (declaration), `:202-246`
(`approvePackage`)

The constant's own NatSpec promised a bounded scheduling horizon. It appeared exactly
once in the codebase — its own declaration. `approvePackage` accepted any `expiresAt`,
including `0` (no expiry) and `type(uint48).max`, so a package could be parked for
millennia and fired against a treasury whose governance had since changed.

**Fix.** `approvePackage` now enforces `expiresAt <= block.timestamp + MAX_PACKAGE_EXPIRY`
via a new `ExpiryWindowTooLong` error, alongside the existing lower-bound check.

**Regression tests** `test_M2_FarFutureExpiryRejected`, `test_M2_ExpiryWithinHorizonAccepted`.

**Confidence:** High. No assumptions.

---

## [LOW] A successor of a cancelled predecessor was permanently unexecutable and unclosable

**Location** `:221-227` (validation), `:307-310` (execution gate), `:249-259`
(`closeExpiredPackage`)

The comment claimed a predecessor must "not already be finalized as cancelled"; the
code only checked existence. Execution requires `pred.executed`, which a cancelled
package never satisfies. And `closeExpiredPackage` required `expiresAt != 0`, so a
successor approved with `expiresAt = 0` had no permissionless cleanup path at all —
only governance `cancelPackage`.

**Fix.** `approvePackage` now rejects a predecessor that is cancelled or already
executed (`PredecessorFinalized`). Defensively, `closeExpiredPackage` also accepts a
cancelled predecessor as a valid finalization reason, so any package that still ends up
stranded — including one created before this fix — can be cleaned up by anyone. A
merely *pending* predecessor deliberately does not qualify; that package may still run
in order.

**Regression tests** `test_M3_CancelledPredecessorRejected`,
`test_M3_ExecutedPredecessorRejected`, `test_M3_StrandedSuccessorIsClosable`,
`test_M3_PendingPredecessorIsNotClosable`.

**Confidence:** High. No assumptions.

---

## Observations (security-relevant, not vulnerabilities)

**O1 — `setERC20ReserveFloor` had no on-chain effect, and its name implied it did.**
It wrote `erc20ReserveFloors[token]` and emitted an event; nothing in `_executePackage`
read the mapping. The treasury executes arbitrary target calldata and cannot determine
which tokens a call moves, so on-chain enforcement is genuinely not possible — but an
operator configuring a floor would reasonably believe ERC20 balances were protected.
**Fixed** by renaming to `setERC20ReserveFloorReference` / `erc20ReserveFloorReferences`
/ `ERC20ReserveFloorReferenceSet` and stating in the NatSpec, the state variable comment
and `SECURITY.md` §5 that it is a published value for off-chain monitoring, not a
control.

**O2 — A code comment cited a constraint that does not exist.** `EnterpriseDAO.sol`
justified routing to `_setProposalThreshold` over `super.setProposalThreshold` by
referring to a "whitelist deque check" that drains a deque and reverts. The pinned
dependency, OpenZeppelin 5.1.0 `GovernorSettings`, contains no whitelist, queue or
deque of any kind — verified by reading the vendored source. The routing is correct and
harmless; the stated reason was fiction, and would send a maintainer hunting for a
constraint that isn't there. **Fixed** — the comment now states the actual reason.

**O3 — Dead code.** The `PackageApproved` (V1) event was declared but never emitted
(`rg "emit PackageApproved\("` returns nothing), and the `PredecessorCycle` guard sat
inside an `if (predecessor != bytes32(0))` block where it was unreachable — it also
referenced the still-zero named return `packageId`. **Fixed** — both deleted.

**O4 — `closeExpiredPackage` reused `PackageNotReady` for the "not yet expired" case**,
the inverse of the name's meaning, so indexers could not distinguish "too early" from
"expired, finalising". **Fixed** with a dedicated `PackageNotExpired` error.

---

# Verified sound (checked directly, not assumed)

- **Role graph — no escalation, and the split adds none.** `DEFAULT_ADMIN_ROLE` is held
  only by `address(this)`; `GOVERNANCE_ROLE`, `GUARDIAN_ROLE` and `RISK_LIMITER_ROLE` are
  all self-administered. The only path to a role change is a self-targeted governance
  package. The full `DEFAULT_ADMIN → GOVERNANCE → {GOVERNANCE, RISK_LIMITER}` and
  `→ GUARDIAN` graph was traced; no lower role reaches a higher one, and the root
  itself holds no operational role.
- **Reentrancy — closed.** `executed = true` is written before the external call, and
  both execution entry points carry `nonReentrant`. Every externally callable function
  was enumerated; none writes to an existing package's fields, so a re-entering target
  has nothing to corrupt. Covered by `test_ExecutePackageReentrancyBlocked` and
  `test_ReentrantDepositCannotDoubleCount`.
- **Quorum is snapshot-safe.** `quorum()` reads `getPastTotalSupply(timepoint)`, never
  current supply, and `GovernorCountingSimple` passes `proposalSnapshot(proposalId)`.
  Flash-loan, same-block mint/burn and post-snapshot transfers cannot move a live
  proposal's quorum. The ramp is monotonic, and `quorumFractionAtSupply` cannot divide
  by zero at `low == high` because the middle branch is only reachable when
  `low < supply < high`. `Math.mulDiv` is 512-bit.
- **Package identity.** `packageId` binds `address(this)` plus a strictly increasing
  `nextPackageNonce` seeded at 1. No collision, no replay, no cross-tenant substitution.
  `invariant_NonceMonotonic` covers it.
- **Token supply.** Minted once in the constructor to a non-zero recipient. No owner,
  no mint path. The `_update` and `nonces` overrides are the correct OpenZeppelin
  resolution of the ERC20/ERC20Votes and ERC20Permit/Nonces collisions.
- **OpenZeppelin 5.1.0 is not in the advisory set.** `TimelockController.updateDelay`
  is `sender != address(this)` gated, so CVE-2021-39167/39168 is patched. No `ECDSA`,
  `Base64`, `Bytes.lastIndexOf`, `ERC165Checker` or executor-escalation surface is
  reachable. There are no proxies, so SCWE-092 and modular-delegatecall storage
  collision do not apply.
- **Guardian scope.** Guardian cancellation is confined to `block.timestamp <
  executeAfter`; `unpause` is `GOVERNANCE_ROLE`-only; the guardian can touch no risk
  limit, holds no custody path, and cannot create packages.
- **Open executor is safe.** `EXECUTOR_ROLE` granted to `address(0)` only permits
  executing an already-queued, already-matured operation. The delay is enforced by the
  timelock itself, not by the executor's identity.

---

## Verdict

The access-control core was well built from the start: no role escalation, no
reentrancy, snapshot-safe quorum, correct package identity, and an OpenZeppelin
version outside the advisory set. The single serious defect was structural rather than
a missing check — the risk limits were all held by the same key they were meant to
constrain, so a documented defence against governance capture did not exist.

That is now fixed with an immutable delay floor plus split governance/limiter
authority, and every fix is pinned by a regression test that fails against the
pre-fix contract. The residual exposure is the one no contract can close: if the
governor and the risk limiter are compromised *simultaneously*, the caps and the
allowlist can both be lifted, and only `minTierDelay` stands between that and a full
drain. Independent multisigs with disjoint signers are the control, and the deploy
script now refuses a topology that makes the two roles the same.

This is materially closer to audit-grade than the previous state. It is still not a
substitute for independent professional review of these exact commits, and the
`forge test --profile ci` and Slither runs listed in `SECURITY.md` should be completed
before real funds.
