# Coverage

Generated with `forge coverage --no-match-test "testFuzz_|invariant_"` (unit suites
only — the fuzz and invariant suites in `test/TreasuryFuzz.t.sol`,
`test/GovernanceAttack.t.sol` and `test/TreasuryInvariant.t.sol` exercise further
paths on top of these numbers). CI re-runs this on every push and uploads the
full `lcov.info` artifact.

| File | Lines | Statements | Branches | Functions |
| --- | ---: | ---: | ---: | ---: |
| contracts/DAOGovernanceToken.sol | 100.00% (7/7) | 100.00% (6/6) | 100.00% (1/1) | 100.00% (3/3) |
| contracts/DAOTreasuryExecutionEngine.sol | 95.00% (190/200) | 86.22% (219/254) | 53.45% (31/58) | 94.12% (32/34) |
| contracts/EnterpriseDAO.sol | 81.43% (57/70) | 85.71% (60/70) | 75.00% (6/8) | 75.00% (15/20) |
| contracts/VestingVault.sol | 92.31% (48/52) | 86.96% (60/69) | 70.59% (12/17) | 88.89% (8/9) |
| script/Deploy.s.sol | 100.00% (73/73) | 100.00% (80/80) | 50.00% (21/42) | 100.00% (5/5) |
| **Total** | **77.84% (425/546)** | **78.37% (453/578)** | **53.62% (74/138)** | **67.97% (87/128)** |

Uncovered lines are concentrated in defensive branches (unreachable-cycle guards,
`try/catch` fallbacks for non-compliant tokens, degenerate ramp geometries),
each covered instead by dedicated fuzz or invariant properties where applicable.
