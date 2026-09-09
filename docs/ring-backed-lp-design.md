# Ring-backed hybrid LP

`RingBackedLiqHook` combines a permanent full-range Uniswap v4 position with an optional
per-order JIT position funded by Ring FewV2. The permanent position supplies continuous quotes
and makes the pool visible to ordinary v4 integrations. The JIT position is added in
`beforeSwap` and completely removed in `afterSwap`. Both swap return-delta permissions remain
off; PoolManager performs the native curve accounting.

## Swap flow

1. The hook reads the current v4 price and permanent full-range liquidity.
2. It simulates the requested swap against base plus candidate JIT liquidity. It searches for a
   candidate whose JIT inventory can be purchased through the pinned Ring route. Ring charges its
   fixed 30 bps on every FewV2 hop; the hook adds no 5 bps aggregator fee.
3. The search chooses the closest candidate that never requires Ring-input subsidy. It accepts a
   positive input surplus only within one raw output unit's input quantum. `beforeSwap` then obtains
   the JIT output from Ring, settles that inventory into PoolManager, and adds the real JIT position.
4. The user trades once against the combined curve. `afterSwap` verifies the amounts and ending
   price, removes the entire JIT position, and donates positive rounding credit to the permanent
   full-range LPs.
5. If no safe Ring/JIT match exists, base-only fallback is allowed only while the permanent v4
   marginal price remains within the Ring fee band plus 5% drift tolerance. A larger deviation
   reverts with `QuoteDeviationExceeded`; an arbitrageur can use `RingLPRouter.syncPrice` to trade
   only against the permanent LP and move its price back toward Ring.

Only full-range external positions are accepted. Narrow positions would change active base
liquidity along the path and invalidate the hybrid calculation. Any number of full-range NFT
positions may coexist; their aggregate active liquidity is used by the quote.

The pool has zero v4 LP fee. A nonzero protocol fee is rejected. Ring fees remain embedded in the
Ring leg. Owner-funded rounding reserves cover at most eight raw units per currency per successful
swap and require at least 16 raw units before quoting. They are accounting protection, not trading
inventory. Positive JIT removal dust is donated through PoolManager and accrues to active
full-range LPs.

`quote(key, zeroForOne, amountSpecified)` returns `(ringIn, ringOut, Plan)`. A nonzero
`Plan.liquidity` means the quote uses Ring JIT; zero means base-only fallback.
`Plan.amountIn` and `Plan.amountOut` are the total user fill. Negative `amountSpecified` is
exact input and positive is exact output. The caller must enforce a chosen minimum output or
maximum input and a deadline.

`getSpotDeviationBps(forward)` returns the measured marginal deviation and the allowed directional
band. The band includes 30 bps for each FewV2 hop plus `MAX_SPOT_DEVIATION_BPS` (currently 500).
The synchronization path does not enable hook return deltas: it is an ordinary v4 swap paid by the
caller, with an explicit amount limit, deadline and square-root price limit.

Endpoints must be ERC-20 tokens, so use WETH instead of native ETH. The pinned route contains two
to four distinct canonical Few wrappers. Fee-on-transfer and rebasing assets are unsupported.
The hook is immutable and owner-pausable, uses two-step ownership transfer, and disables ownership
renunciation.

## Sepolia workflow

Copy `.env.ring-backed-sepolia.example` to `.env.ring-backed-sepolia`. The example already
contains the Sepolia PoolManager, PositionManager, Permit2, Few factories, WETH and fwWETH
addresses. Fill only the RPC URL and private key, then run the complete fresh deployment:

```bash
cp .env.ring-backed-sepolia.example .env.ring-backed-sepolia
# Edit SEPOLIA_RPC_URL and SEPOLIA_PRIVATE_KEY.
bash scripts/ring-backed/sepolia.sh deploy-all
```

`deploy-all` runs the build and tests, deploys a new fixed-supply 1-billion RHT, seeds a Ring
pair with 1 WETH and 1,000,000 RHT, deploys the immutable hook and router, initializes the v4
pool, mints the wallet's full-range NFT with up to 0.01 WETH and 10,000 RHT, enables the pool,
and verifies that the hook is live. It updates the generated token, pair, hook, router, path and
NFT addresses in `.env.ring-backed-sepolia`, so no output needs to be copied manually. The wallet
needs a little more than 1.01 Sepolia ETH for liquidity plus deployment gas.

Use `RUN_CHECKS=false bash scripts/ring-backed/sepolia.sh deploy-all` only after the same source
revision has already passed its tests. `SIMULATE=true` is intentionally rejected for this command,
because later stages need the on-chain deployments produced by earlier stages.

The individual subcommands remain available for diagnosis and recovery. To reuse the earlier
seeded Ring pair instead of creating a fresh RHT, fill:

```dotenv
TEST_TOKEN_ADDR=0x30EB24aE5Ff3bd13c91859A99Ca7d95Eb5be0611
TOKEN_A_ADDR=0x30EB24aE5Ff3bd13c91859A99Ca7d95Eb5be0611
TOKEN_B_ADDR=0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14
FW_PATH=0x6027Ed0e3cD2f8DADD86B1134D4C29662CFF8FEf,0x98b902eF4f9fEB2F6982ceEB4E98761294854D61
ZERO_FOR_ONE=false
```

That Ring pair contains 1 WETH and 1,000,000 RHT. Do not run `seed-ring` again. The manual
recovery flow is:

```bash
bash scripts/ring-backed/sepolia.sh check
SIMULATE=true bash scripts/ring-backed/sepolia.sh deploy
bash scripts/ring-backed/sepolia.sh deploy
```

Run the remaining stages in order and simulate each command first. Initialization creates the
pool at the 1 WETH : 1,000,000 RHT price, funds rounding reserves, and leaves it paused.
`add-base-lp` grants Permit2 allowances and mints an official PositionManager NFT owned by the
broadcaster using up to 0.01 WETH and 10,000 RHT. Finally enable swaps:

```bash
SIMULATE=true bash scripts/ring-backed/sepolia.sh initialize
bash scripts/ring-backed/sepolia.sh initialize

SIMULATE=true bash scripts/ring-backed/sepolia.sh add-base-lp
bash scripts/ring-backed/sepolia.sh add-base-lp

ACTION=setPoolLive LIVE=true SIMULATE=true bash scripts/ring-backed/sepolia.sh admin
ACTION=setPoolLive LIVE=true bash scripts/ring-backed/sepolia.sh admin
```

Record `V4_POSITION_TOKEN_ID` from `add-base-lp`. The wallet owns this NFT, so the Uniswap
positions page can index and display it. Indexing may lag the transaction.

For a read-only 0.01 WETH exact-input quote, use sorted currencies
(`currency0=RHT`, `currency1=WETH`):

```bash
cast call "$RING_BACKED_HOOK_ADDR" \
  'quote((address,address,uint24,int24,address),bool,int256)(uint256,uint256,(uint160,uint160,uint128,int24,int24,uint256,uint256))' \
  "($TOKEN_A_ADDR,$TOKEN_B_ADDR,0,$TICK_SPACING,$RING_BACKED_HOOK_ADDR)" \
  false -10000000000000000 --rpc-url "$SEPOLIA_RPC_URL"
```

Set `AMOUNT_SPECIFIED`, `AMOUNT_LIMIT`, and `ZERO_FOR_ONE`, then simulate and broadcast.
A negative amount is exact input; a positive amount is exact output. `AMOUNT_LIMIT` is minimum
output for exact input and maximum input for exact output.

```bash
SIMULATE=true bash scripts/ring-backed/sepolia.sh swap
bash scripts/ring-backed/sepolia.sh swap
```

Local tests use a real v4 PoolManager and a FewV2 pair fixture enforcing the adjusted-product
invariant. This construction has not received an independent audit. Measure full transaction gas
and validate both directions and exact-input/output behavior before production use.
