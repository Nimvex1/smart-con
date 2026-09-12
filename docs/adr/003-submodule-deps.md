# ADR-003: Pinned submodules over vendored dependencies

- Status: accepted.
- Context: `lib/` carried full vendored copies of OpenZeppelin and forge-std
  (~80k lines), dwarfing the audited surface, slowing clones, and inviting silent
  drift from upstream tags.
- Decision: depth-pinned git submodules at OpenZeppelin `v5.1.0` and forge-std
  `v1.9.7`; CI checks out recursively. Same paths, same versions, auditable pins.
- Consequences: cloners must use `--recurse-submodules`; estimators and auditors
  see the original surface instead of third-party code.
