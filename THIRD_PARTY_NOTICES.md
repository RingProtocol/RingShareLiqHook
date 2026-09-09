# Third-party notices

This repository uses fixed git submodules for Foundry, Uniswap v4 core, and OpenZeppelin Contracts.
Their upstream licenses remain in their respective submodule directories:

- `lib/forge-std` — MIT
- `lib/v4-core` — Business Source License 1.1 and GPL-2.0-or-later, by file
- `lib/openzeppelin-contracts` — MIT

Files under `src/alf/` were adapted from Uniswap Labs' public hook work and retain their original
attribution and SPDX identifiers. The minimal Few Protocol interfaces under
`src/interfaces/external/` retain their per-file GPL-2.0-or-later identifiers.

The repository-level MIT license applies only where a file does not state a different license.

`src/libraries/FewV2Math.sol` and `src/interfaces/external/IFewV2.sol` come from the local
`ring-v4-aggregator-hook-audit` reference repository (revision
`1258a57d8f78cd23f26eeb38e0c84e50b27225c1`) and retain GPL-2.0-or-later identifiers.
`RingBackedLiqHook` adapts its canonical FewToken validation and FewV2 execution patterns,
but uses real v4 LP positions with no custom swap-return deltas. The adapted implementation
is not covered by any audit of that reference repository.
