# ADR-001: Global spend rate limit

- Status: accepted.
- Context: tier caps bound value *per package*, but a captured governance can pass
  many packages. No bound existed on aggregate outflow per time window.
- Decision: `nativeSpendLimit` per `spendWindow` (0 disables), enforced in
  `_executePackage` with automatic window rollover. Reconfiguring restarts the
  budget immediately so tightening takes effect at once.
- Consequences: legitimate high-tempo spending must size the window accordingly;
  the limiter is a backstop, not a budget tool. See `Hardening.t.sol`
  `test_SpendLimitBoundsOutflowPerWindow`.
