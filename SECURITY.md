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
     ▼                                   │
DAOTreasuryExecutionEngine ◀──────── Guardian multisig
     │  (packages: delayed, permissionless execution)
     ▼
Arbitrary targets (calls + native value)
```

**Funds movement is only possible through a chain that requires:**
1. A proposal that passes the governor (dynamic quorum + majority of cast votes),
2. The timelock delay elapsing (default 2 days),
3. The treasury tier quarantine delay elapsing (1–14 days by tier),
4. Then *anyone* may execute the package.

The shortest possible path from "decision" to "funds move" is therefore
`voting period + 2 days + tier delay`. No single key can shortcut it.

## Who can move funds

| Actor | Can move funds directly? | Conditions |
|---|---|---|
| Token holder | No | Can only vote / propose |
| Governor | No | Only via timelock operations |
| Timelock | Only indirectly | Executes passed proposals after delay |
| Treasury GOVERNANCE_ROLE (the timelock) | No | Only *schedules* packages (funds move at permissionless execution) |
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

**If compromised, worst case:**
- Denial-of-service: pause the treasury and cancel fresh packages. Funds are **not
  at risk of theft**, but withdrawals halt until governance (which the guardian cannot
  stop) unpauses. Post-quarantine cancellation is impossible, so any package whose
  window has elapsed still executes.

**Mitigations:** time-bound window (`GuardianCancelWindowClosed`), pause/unpause split,
zero custody, all powers reviewed above are tested in `TreasuryFuzz.t.sol` and
`TreasuryInvariant.t.sol`.

### 2. The Timelock (TimelockController)

- Holds `GOVERNANCE_ROLE` on the treasury; it is the *only* scheduler of packages.
- `EXECUTOR_ROLE` is open (`address(0)`): anyone can execute a *ready* timelock
  operation — this is a liveness feature, not a power grant.
- Initially administered by the deployer; the deployer **must renounce**
  `DEFAULT_ADMIN_ROLE` after bootstrap (see `DAODeploymentNotes.sol`).

**If compromised (e.g. admin key never renounced):**
- An attacker controlling the timelock admin can schedule arbitrary treasury
  packages. Each package still waits out its tier delay (1–14 days), giving the
  community a detection window, but the funds are ultimately movable.
- This is why renunciation is the mandatory final deployment step and is asserted
  in the deploy script's checklist output.

### 3. The Governor

- Proposal threshold is bounded by immutable min/max; quorum parameters are immutable.
- Voting delay/period are floored at their deployment values (`minimumVotingDelay` /
  `minimumVotingPeriod`): governance may lengthen debate, never shorten it, so a
  captured majority cannot rush follow-up proposals through 1-block votes.
- `setProposalThreshold` is `onlyGovernance` and clamped to the immutable bounds
  (fix for the v1 access-control regression — see README).
- Dynamic quorum is snapshot-safe: `getPastTotalSupply` is used, so flash-loan /
  same-block supply manipulation cannot lower a live proposal's quorum
  (tested in `GovernanceAttack.t.sol`).

**If 50% of voting power is captured:**
- The attacker can pass any proposal but still waits out the timelock + tier delays;
  the delay ladder is the last line of defense. Tiers cap native value per package
  (5–250 ETH), and the destination allowlist + reserve floors can be pre-configured
  to bound the blast radius even under full capture.

### 4. Treasury tier configuration
- Only GOVERNANCE_ROLE (the timelock). Delays bounded to `MIN_TIER_DELAY = 1 hour`
  .. `MAX_TIER_DELAY = 365 days`; value caps are arbitrary but set at construction.
- **Execution-time revalidation:** allowlist membership, tier enabled-state and value
  caps are checked again at execution, so policy tightened after scheduling (during
  incident response) still stops pre-staged packages.
- **Optional destination allowlist:** once enabled, packages may only target
  allowlisted addresses — a hard containment boundary. Enabling requires the
  treasury itself to be listed, so governance cannot brick its own management path.
- **Optional native reserve floor:** execution that would drop the ETH balance below
  the floor reverts (`ReserveFloorBreached`).
- **Optional global spend rate limit** (`nativeSpendLimit` per `spendWindow`, 0 = off):
  bounds native outflow per window even under full governance capture. The window
  resets automatically; reconfiguring restarts the budget immediately.
- **Per-token ERC20 reserve floors** are enforced on-chain for packages that target
  the token contract directly (post-execution balance check); indirect routes (an
  attacker contract that calls the token) are contained by the allowlist and
  off-chain monitoring.
- **Package expiry** is capped at `MAX_PACKAGE_EXPIRY = 365 days` from scheduling.

### 5. Vesting vault

- Schedules are created only by GOVERNANCE_ROLE (the timelock) and funded with an
  allowance-based pull, so no schedule exists without a passed proposal.
- Claims are permissionless but can only pay the recorded beneficiary; revocation
  returns only the unvested remainder to a governance-chosen address while vested
  tokens stay claimable. Vesting freezes at the revocation timestamp.
- The vault holds no roles on the treasury and cannot move treasury funds — it only
  escrows what governance explicitly funds it with.

## Package lifecycle guarantees

For every package id, exactly one of the following is true at any time:
`Pending → (Executed | Cancelled | Expired)` — finality is exclusive
(`PackageAlreadyFinalized`). Invariants (see `TreasuryInvariant.t.sol`):

1. An executed package can **never** execute again.
2. A cancelled package can **never** execute.
3. An expired package (`expiresAt` passed) can **never** execute; anyone may finalize
   it via `closeExpiredPackage`.
4. A package with a predecessor can only execute after the predecessor executed.
5. Only GOVERNANCE_ROLE can ever create a package — no other path exists
   (fuzzed across every account).
6. Package ids commit to `(contract, target, value, calldata hash, tier, nonce)` —
   substitution or replay of any field produces a different, unknown id.

## Failure modes and responses

| Failure | Effect | Response |
|---|---|---|
| Guardian key theft | DoS only (pause/cancel window) | Rotate GUARDIAN_ROLE via governance; wait out quarantine |
| Timelock admin not renounced | Ultimate power retained by deployer | Renounce immediately (asserted at deploy) |
| Malicious token deposited | Token-side accounting lies | Treasury never trusts token balances for control flow; SafeERC20 for transfers |
| Reentrant target | Attempted double execution | `nonReentrant` on execute paths; tested with a reentering target |
| Gas-griefing target | Package execution reverts | Execution is permissionless and retryable; `executed` flag rolls back on failure |
| Quorum flash-loan | Same-block supply swing | Snapshot-safe quorum via historical checkpoints |
| Expired package confusion | Stale calldata executed | Explicit `expiresAt` deadline checked before execution |
| Full governance capture | Unbounded drain at tier caps | Spend rate limit + reserve floors + allowlist bound loss per window |

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
