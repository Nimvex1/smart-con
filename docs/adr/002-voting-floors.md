# ADR-002: Lengthen-only voting windows

- Status: accepted.
- Context: OZ `GovernorSettings` lets governance set any voting delay/period. A
  captured majority could pin 1-block votes and rush follow-up proposals before
  defenders react.
- Decision: `minimumVotingDelay` / `minimumVotingPeriod` snap to deployment values
  as immutables; setters only accept values at or above them. No `GovernorConfig`
  change was needed, so existing wiring is untouched.
- Consequences: legitimately shortening debate later is impossible without
  redeploying the governor; lengthening is always available.
