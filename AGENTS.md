# Project guidance

- `RingShareLiqHook` is deprecated. Current backend work targets `RingBackedLiqHook` (FewV2) and `RingV4BackedLiqHook` (FewToken v4).
- Keep the V2 implementation and the sibling `RingFallbackHook` repository unchanged when working on the V4-backed implementation unless explicitly requested.
- Both backed hooks use a single outer pool, full-range permanent liquidity, ordinary v4 swap deltas, and the prefunded `RingLPRouter`. `syncPrice` is a caller-funded trade against permanent liquidity, not an oracle update.
- V4 backend registration is explicit, uses the same PoolManager, and accepts only hookless, static-fee ERC20 FewToken pools. Wrapper ordering can differ from underlying-token ordering. Native currency and multihop backend routes are not supported.
- `FewV4Quoter` is a full-fill backend quote, not a general partial-fill preview. It uses the backend execution's extreme price limit, includes directional protocol fees, and rejects dust, incomplete fills, and swaps requiring more than 512 bitmap/tick steps.
- Preserve exact 1:1 wrapper balance checks, zero backend currency deltas after settlement, and the eight-raw-unit per-currency hook rounding-loss cap. This cap does not establish permanent-LP economic safety.
