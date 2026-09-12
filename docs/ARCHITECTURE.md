# Architecture

Token holders govern through `EnterpriseDAO` (OZ Governor + TimelockControl);
the timelock alone holds `GOVERNANCE_ROLE` on `DAOTreasuryExecutionEngine`, so
every wei leaves the treasury only after proposal → timelock delay → tier
quarantine. Execution itself is permissionless after quarantine (liveness).

```
Token holders --vote--> EnterpriseDAO --queue/execute--> TimelockController
                                                              |
                              GOVERNANCE_ROLE (schedule)      | GUARDIAN_ROLE
                                                              v (pause, quarantine-window cancel)
                        DAOTreasuryExecutionEngine <---- Guardian multisig
                              |  (packages: target/value/calldata/tier/nonce)
                              v  (anyone executes when ready)
                        Arbitrary targets (+ VestingVault schedules)
```

## Key decisions (see `docs/adr/`)

- Allowlist, tier state and value caps are revalidated at execution, not just
  scheduling, so incident response stops pre-staged packages.
- A global spend rate limit bounds outflow per window even under full capture.
- Voting delay/period are lengthen-only past deployment values.
- Dependencies are pinned submodules, never vendored blobs.

## Testing map

| Suite | What it proves |
| --- | --- |
| Unit (`DAO*.t.sol`, `EnterpriseDAO.t.sol`, `VestingVault.t.sol`) | Lifecycle, snapshot safety, quorum math, vesting, deploy wiring |
| Fuzz (`TreasuryFuzz.t.sol`, `GovernanceAttack.t.sol`) | Boundaries, timing, allowlist/floors, adversarial governance |
| Invariant (`TreasuryInvariant.t.sol`) | Finality exclusivity, scheduling ACL |
| Malicious (`MaliciousToken.t.sol`) | Hostile tokens/targets, reentrancy, gas griefing |
| Hardening (`Hardening.t.sol`) | Every post-audit guarantee in one place |
