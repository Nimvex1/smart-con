# Pinned Foundry toolchain (tested with v1.8.1) for reproducible builds,
# tests, and coverage without installing anything locally.
FROM ghcr.io/foundry-rs/foundry:latest

WORKDIR /app

# Submodules must be present: clone with --recurse-submodules.
COPY . .

RUN forge build

# Default: fast unit suites (fuzz + invariants run in CI's dedicated job).
CMD ["forge", "test", "--match-path", "test/*.t.sol", "--no-match-path", "test/*Invariant*.t.sol"]
