## What and why (one paragraph)

## Verification

- [ ] `forge build` clean
- [ ] `forge test --match-path 'test/*.t.sol' --no-match-path 'test/*Invariant*.t.sol'` green
- [ ] `forge fmt --check` clean
- [ ] Gas snapshot regenerated if execution gas changed (`forge snapshot`)

## Security notes (new attack surface? new trust assumptions?)
