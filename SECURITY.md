# Security Model — Enterprise DAO Ecosystem

This document is the formal threat model for the system. It answers, for every
privileged component: **who can move funds, under what conditions, what each
emergency actor can and cannot do, and what happens if that actor is compromised.**

## System topology

```
Token holders
     │  (vote)
     ▼
EnterpriseDAO (Governor)
     │  (queue + execute proposals)
     ▼
TimelockController  ──holds──▶ GOVERNANCE_ROLE on Treasury
     │                                   ▲
     │                                   │ GUARDIAN_ROLE
     │                                   │
     │   ┌──holds──▶ RISK_LIMITER_ROLE ──┘
     │   │            (loosen risk limits only)
     ▼   │
DAOTreasuryExecutionEngine ◀── Security council (independent key)
     │  (packages: delayed, permissionless execution)
     ▼
Arbitrary targets (calls + native value)
```

**Funds movement is only possible through a chain that requires:**
1. A proposal that passes the governor (dynamic quorum + majority of cast votes),
2. The timelock delay elapsing (default 2 days),
3. The treasury tier quarantine delay elapsing (at least `minTierDelay`, immutable),
4. Then *anyone* may execute the package.

The shortest possible path from "decision" to "funds move" is therefore
`voting period + 2 days + minTierDelay`. No single key can shortcut it, and
critically, **no single key can remove any of the risk limits** a package must
respect — see §6.

## Who can move funds

| Actor | Can move funds directly? | Conditions |
|---|---|---|
| Token holder | No | Can only vote / propose |
| Governor | No | Only via timelock operations |
| Timelock | Only indirectly | Executes passed proposals after delay |
| Treasury GOVERNANCE_ROLE (the timelock) | No | Only *schedules* packages (funds move at permissionless execution) |
| Treasury RISK_LIMITER_ROLE | No | Can only loosen risk limits; cannot schedule, execute, pause or unpause |
| Guardian | **No** | Has zero fund-movement authority (see below) |
| Random address | No | May only *execute* already-approved packages after all delays |
| Deployer | No (post-bootstrap) | Must renounce admin on the timelock |

## Privileged components and compromise analysis

### 1. The Guardian (multisig)

**Powers:**
- `pause()` — halt package execution and deposits, any time.
- `cancelPackage(id)` — cancel a package, **only before its `executeAfter`** (the quarantine window).

**Cannot:**
- Move, withdraw, or redirect funds.
- Unpause (`unpause()` is GOVERNANCE_ROLE-only, i.e. requires a full proposal + timelock delay).
- Cancel after the quarantine window closes.
- Configure tiers, thresholds, or the allowlist.
- Grant or revoke any role.
- Loosen or tighten any risk limit (that is `RISK_LIMITER_ROLE`, §6).

**If compromised, worst case:**
- Denial-of-service: pause the treasury and cancel fresh packages. Funds are **not
  at risk of theft**, but withdrawals halt until governance (which the guardian cannot
  stop) unpauses. Post-quarantine cancellation is impossible, so any package whose
  window has elapsed still executes.

**Mitigations:** time-bound window (`GuardianCancelWindowClosed`), pause/unpause split,
zero custody, all powers reviewed above are tested in `TreasuryFuzz.t.sol` and
`TreasuryInvariant.t.sol`.

### 2. The Risk Limiter (security council)

**Powers:**
- Loosen the tier delay (down to but never below `minTierDelay`), raise a tier's
  `maxNativeValue`, re-enable a disabled tier, disable the destination allowlist,
  remove a listed destination, and lower the native reserve floor.

**Cannot:**
- Schedule, execute, or cancel any package.
- Pause or unpause.
- Move, withdraw, or redirect funds.
- Grant or revoke any role.
- Set any tier delay below the immutable `minTierDelay` — this is not a permission, it
  is unreachable from every role including the treasury's own root.

**If compromised, worst case:**
- All limits except the delay floor can be widened. Funds still cannot move without a
  governance-approved package, and every such package still waits at least
  `minTierDelay`. No immediate loss; the loss requires a second, independent compromise.

**Why the roles are not stacked:** if the limiter and the governor were the same entity,
a single compromise would both schedule a package and remove the constraints that
package must respect, reproducing the pre-fix design. `script/Deploy.s.sol` reverts the
deployment if either entity holds the other's role.

### 3. The Timelock (TimelockController)

- Holds `GOVERNANCE_ROLE` on the treasury; it is the *only* scheduler of packages.
- `EXECUTOR_ROLE` is open (`address(0)`): anyone can execute a *ready* timelock
  operation — this is a liveness feature, not a power grant.
- Initially administered by the deployer; the deployer **must renounce**
  `DEFAULT_ADMIN_ROLE` after bootstrap (see `DAODeploymentNotes.sol`).

**If compromised (e.g. admin key never renounced):**
- An attacker controlling the timelock admin can schedule arbitrary treasury
  packages. Each package still waits out a quarantine of at least the immutable
  `minTierDelay`, and the value caps, allowlist and floor in force still apply
  because widening them needs the risk limiter. The delay is the community's
  detection window; the limits are what bound the damage afterwards.
- This is why renunciation is the mandatory final deployment step and is asserted
  in the deploy script's checklist output.

### 4. The Governor

- Proposal threshold is bounded by immutable min/max; quorum parameters are immutable.
- `setProposalThreshold` is `onlyGovernance` and clamped to the immutable bounds
  (fix for the v1 access-control regression — see README).
- Dynamic quorum is snapshot-safe: `getPastTotalSupply` is used, so flash-loan /
  same-block supply manipulation cannot lower a live proposal's quorum
  (tested in `GovernanceAttack.t.sol`).

**If 50% of voting power is captured:**
- The attacker can pass any proposal, but still waits out the timelock delay plus the
  quarantine delay, which **cannot go below the immutable `minTierDelay`**.
- The attacker **cannot** raise a tier's value cap, disable the destination allowlist,
  remove a listed destination, or lower the native reserve floor. Each of those requires
  `RISK_LIMITER_ROLE`, a separate key. See §6.
- Therefore, under governance capture alone, every package is still bounded by the caps,
  the allowlist and the floor as they stand. The blast radius is bounded by configuration
  the attacker does not control.
- **Honest limit of this claim:** it does not survive *simultaneous* compromise of
  governance and the risk limiter. An attacker holding both can raise the caps to
  unbounded and lift the allowlist, then drain after `minTierDelay`. The immutable delay
  floor is the one control that still holds in that scenario, which is why it is
  `immutable` rather than governance-mutable. Keeping the two keys genuinely independent
  (separate multisigs, separate signers) is a deployment responsibility, and
  `script/Deploy.s.sol` asserts the roles are not stacked.

### 5. Treasury tier configuration

- Authority is **split**, not stacked. Loosening a risk limit requires
  `RISK_LIMITER_ROLE`; tightening requires `GOVERNANCE_ROLE`. Holding both roles on one
  account is equivalent to the unguarded design and is rejected by the deploy script.
- Delays are bounded on **both** sides: `delay <= MAX_TIER_DELAY` (365 days) and
  `delay >= minTierDelay` (immutable, set at construction, must be non-zero).
- **Optional destination allowlist:** once enabled, packages may only target
  allowlisted addresses. Disabling it or removing a destination requires the limiter.
- **Optional native reserve floor:** execution that would drop the ETH balance below
  the floor reverts (`ReserveFloorBreached`). Lowering the floor requires the limiter.
  This floor *is* enforced on-chain, in `_executePackage`, for packages that forward
  native value.
- **Per-token ERC20 reserve floor references** (`erc20ReserveFloorReferences`, set via
  `setERC20ReserveFloorReference`) are **NOT enforced on-chain and are not a security
  control.** The treasury executes arbitrary target calldata and cannot determine which
  tokens a given call moves, so no execution path reads the mapping. The values exist
  only so off-chain monitoring can compare observed balances against a published
  threshold. Do not treat them as spend limits.

### 6. Why the risk limits are not governance-exclusive

Every control that bounds the blast radius of a hostile governor — the tier delay
ladder, the per-tier native value caps, the destination allowlist, and the native
reserve floor — is *mutable by governance*. A control the constrained party can relax
constrains nothing. Before this design was introduced, a single governance batch could
call `configureTier(tier, 0, type(uint256).max, true)`, `setTargetAllowlistEnabled(false)`
and `setNativeReserveFloor(0)`, approve a package for the full native balance, and
execute it in the same block — a complete drain with zero quarantine. That scenario is
now impossible, and `test_M1_GovernanceAloneCannotLoosenAnyRiskLimit` and
`test_CapturedGovernorCannotLoosenRiskLimits` assert it.

Two independent mechanisms prevent it:

| Control | Property | Reachable by |
|---|---|---|
| `minTierDelay` | `immutable`, non-zero | nobody, at any time, by any role |
| Delay below current (but ≥ floor) | loosening | `RISK_LIMITER_ROLE` only |
| Cap increase / tier re-enable | loosening | `RISK_LIMITER_ROLE` only |
| Allowlist disable / destination removal | loosening | `RISK_LIMITER_ROLE` only |
| Native reserve floor decrease | loosening | `RISK_LIMITER_ROLE` only |
| Delay increase / cap decrease / tier disable | tightening | `GOVERNANCE_ROLE` only |
| Allowlist enable / destination addition | tightening | `GOVERNANCE_ROLE` only |
| Native reserve floor increase | tightening | `GOVERNANCE_ROLE` only |
| Scheduling, executing, pausing, unpausing | — | `GOVERNANCE_ROLE` / `GUARDIAN_ROLE` as before |

Tightening deliberately stays governance-only so that containing an incident never
depends on a second key being reachable. The limiter cannot schedule or execute
anything, so compromising it alone moves no funds; it can only widen limits that
governance must still use. Compromising governance alone can schedule packages but
cannot widen a single limit, and cannot shorten the delay below `minTierDelay`.

## Package lifecycle guarantees

For every package id, exactly one of the following is true at any time:
`Pending → (Executed | Cancelled | Expired)` — finality is exclusive
(`PackageAlreadyFinalized`). Invariants (see `TreasuryInvariant.t.sol`):

1. An executed package can **never** execute again.
2. A cancelled package can **never** execute.
3. An expired package (`expiresAt` passed) can **never** execute; anyone may finalize
   it via `closeExpiredPackage`. `expiresAt` must be non-zero and within
   `MAX_PACKAGE_EXPIRY` (365 days) of approval, so a package cannot be parked for
   years and fired against a treasury whose governance has since changed.
4. A package with a predecessor can only execute after the predecessor executed.
   `approvePackage` rejects a predecessor that is already cancelled or executed
   (`PredecessorFinalized`), so no package can be created that can never run. A
   successor that becomes stranded because its predecessor was later cancelled is
   still closable by anyone via `closeExpiredPackage`, even with `expiresAt == 0`.
5. Only GOVERNANCE_ROLE can ever create a package — no other path exists
   (fuzzed across every account). The risk limiter and the guardian cannot schedule.
6. Package ids commit to `(contract, target, value, calldata hash, tier, nonce)` —
   substitution or replay of any field produces a different, unknown id.
7. No tier delay can ever be set below `minTierDelay`, by any account, including the
   treasury's own self-administered root.

## Failure modes and responses

| Failure | Effect | Response |
|---|---|---|
| Guardian key theft | DoS only (pause/cancel window) | Rotate GUARDIAN_ROLE via governance; wait out quarantine |
| Risk limiter key theft | Caps and containment can be widened; funds still gated by `minTierDelay` | Rotate RISK_LIMITER_ROLE via governance; the floor and the tier delay still apply |
| Timelock admin not renounced | Ultimate power retained by deployer | Renounce immediately (asserted at deploy) |
| Limiter and governor collude | Full removal of caps, allowlist and floor | Not preventable on-chain; prevented operationally by using independent multisigs and signers |
| Malicious token deposited | Token-side accounting lies | Treasury never trusts token balances for control flow; SafeERC20 for transfers |
| Reentrant target | Attempted double execution | `nonReentrant` on execute paths; tested with a reentering target |
| Gas-griefing target | Package execution reverts | Execution is permissionless and retryable; `executed` flag rolls back on failure |
| Quorum flash-loan | Same-block supply swing | Snapshot-safe quorum via historical checkpoints |
| Expired package confusion | Stale calldata executed | Explicit `expiresAt` deadline checked before execution |
| Stranded successor | Package that can never execute | `closeExpiredPackage` accepts a cancelled predecessor as a valid finalization reason |

## Audit posture

This repository contains extensive adversarial tests (fuzzing, invariants,
malicious-token suites, governance attack simulations) but **has not undergone a
professional third-party audit**. Before deploying real assets:
1. Commission an independent audit of these exact commits.
2. Run `forge test --profile ci` and Slither in CI (both are wired).
3. Review the deployment checklist in `contracts/DAODeploymentNotes.sol`.

## Reporting a vulnerability

Please report suspected vulnerabilities privately to the repository maintainers.
Do not open public issues for exploitable findings.
