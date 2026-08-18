# Ring Share Liquidity Hook — Beginner's Guide

> This document is written for business, operations, and non-technical readers. It explains in plain language what `RingShareLiqHook` is, what problem it solves, and how it is used.

---

## 1. What is it?

**Ring Share Liquidity Hook** is a "smart market-making assistant" attached to Uniswap V4.

A traditional DEX pool needs someone to lock capital in it long-term as liquidity (being an LP), taking on price risk the whole time. RingShareLiqHook shortens the time capital actually spends inside an LP position using a **JIT (Just-In-Time)** approach:

- Normally: the hook's capital is **not** locked in the pool — it sits on standby
- The moment someone swaps: the hook instantly injects the capital into the pool to provide depth for that trade
- When the trade completes: the hook immediately pulls the capital back out and collects the fee

**In one sentence: the FewToken reserve assigned to a pool is temporarily "lent" to that pool while a trade passes through, and taken back as soon as the trade ends — it never has to sit in an LP position long-term.**

Each hook instance serves **exactly one pool**, and only the hook's owner can supply capital — there are no outside LPs. Hooks are created through a Ring allowlisted factory, so routers and aggregators can verify that deployment against a fixed Ring build. This provenance does not imply Uniswap review, routing support, or endorsement.

---

## 2. Why is it needed?

### The problem: the traditional LP dilemma

| Pain point | Traditional LP | RingShareLiqHook |
|---|---|---|
| Capital occupation | Capital sits in an LP position long-term | The reserve enters an LP position only for the duration of a swap |
| Price risk | Continuously exposed to LP position price changes | Exposure time is shortened — but adverse selection, inventory drift, and mark-to-market swings remain |
| Capital source | Anyone can LP | Only the hook owner supplies capital; external liquidity is rejected |
| Management cost | Monitor positions, adjust ranges, withdraw LP | The hook handles it automatically; the owner only maintains the reserve |

### An analogy

Think of a "pop-up stall" versus a "permanent shop":

- **Permanent shop (traditional LP):** rent a storefront, stock inventory, stay open 24/7 whether or not customers come
- **Pop-up stall (RingShareLiqHook):** set up only when a customer arrives, pack up when the sale is done; each market has its own separately registered goods — one hook instance, one pool

---

## 3. How does it work? (no code)

### Normal flow

```
1. A user initiates a swap (e.g. buying WETH with USDC)
2. The hook checks:
   - Is the pool live (bootstrapped and not paused)?
   - Is the current price inside a configured range?
   - Is the reserve usable?
3. Checks pass → the hook injects the reserve into the pool
4. The V4 pool executes the swap normally (the user trades against deeper liquidity)
5. The hook withdraws the capital + collects the fee
6. The hook re-wraps the capital into fwToken and waits for the next trade
```

### Non-intervention and failure boundaries

- **Pool paused or never bootstrapped** → the swap reverts with an explicit error, so routers know immediately not to route through this pool.
- **Price outside all configured ranges, or no active reserve liquidity** → `beforeSwap` reverts with `NoActiveLiquidity` before the pool price can change.
- **If a JIT cycle has already started** and any later step fails (unwrap, liquidity modification, settlement, wrap), the entire swap rolls back atomically — nothing is left half-done.

---

## 4. What is fwToken?

**fwToken (Few Wrapped Token)** is a 1:1 wrapped version of an origin token:

- 1 USDC → wrap → 1 fwUSDC
- 1 fwUSDC → unwrap → 1 USDC

RingShareLiqHook holds its reserves as fwTokens. In each JIT cycle:

1. `unwrap`: convert fwToken back to the origin token and inject it into the V4 pool
2. The trade completes; withdraw the origin token + fee
3. `wrap`: convert the origin token back into fwToken and keep holding it

**Why fwToken?** A unified capital-management interface, aligned with the Few Protocol ecosystem. The owner manages the reserve with `bootstrap` / `deposit` / `withdraw`.

---

## 5. Quick reference: key terms

| Term | Meaning | Business interpretation |
|---|---|---|
| **JIT liquidity** | Just-In-Time liquidity, injected at the moment of a trade | "Set up the stall only when a customer arrives" |
| **fwToken** | 1:1 wrapper of an origin token | "A standardized deposit receipt for tokens" |
| **Reserve** | The fwToken balance held by the hook | "How much goods the stall has" |
| **Distribution** | Configuration of tick ranges and weights | "At which price points to set up, and how much stock at each" |
| **Bucket** | One tick range + a weight | "One stall spot" |
| **bootstrap** | Seed the reserve and open the pool for business (one-time) | "Grand opening" |
| **setPoolLive** | Pause / resume the pool's JIT service | "Close / reopen the stall" |
| **Laddered distribution** | Multiple adjacent, non-overlapping ranges | "Multiple stall tiers — if one side sells out, the other side keeps serving" |

---

## 6. A complete deployment flow

Using Sepolia testnet as the example:

```
Step 1: Deploy the hook contract
  → Via the AllowlistedFactory, mining a CREATE2 salt so the address
    carries the required permission bits (0x2AC0)

Step 2: Initialize the V4 pool (initializePool)
  → Set the pair (e.g. TOKEN_A / TOKEN_B), the initial price (e.g. 1:1),
    and the initial distribution
  → The pool is created "not live" — swaps revert until bootstrap

Step 3: Bootstrap the reserve (bootstrap)
  → The owner wraps tokens into fwTokens and approves the hook
  → bootstrap pulls the fwTokens in as the pool's reserve and flips the pool live
  → One-time only; later top-ups use deposit

Step 4: (Optional) adjust the distribution (setDistribution)
  → Set tick ranges and weights (laddered configuration)
  → e.g. [-600,-180] 25% / [-180,180] 50% / [180,600] 25%
```

After deployment, the pool accepts normal swaps and the hook automatically injects liquidity on each trade.

---

## 7. Risk summary

| Risk | Description | Mitigation |
|---|---|---|
| **Reserve loss** | The reserve can lose money to adverse selection (arbitrageurs exploiting stale quotes) | Fund each pool only with what you can afford to lose; monitor reserve balances |
| **One-sided depletion** | Persistent one-directional flow can exhaust one side of the reserve | Laddered distribution; owner manually rebalances |
| **Price drift** | The pool price moves out of all bucket ranges | Owner calls `setDistribution` to move the ranges |
| **No fallback liquidity** | The hook is the pool's only liquidity source; when it does not quote, swaps fail | Keep the pool live and in range; monitor liveness |
| **Key compromise** | A leaked owner key can withdraw all reserves | Two-step ownership transfer; key-management best practices |

---

## 8. FAQ

**Q: If the hook doesn't intervene, does the swap fail?**
A: It depends why. A paused pool reverts with `PoolNotLive`. An out-of-range or empty-reserve pool reverts with `NoActiveLiquidity`. Both checks happen before the PoolManager swap, so the price and reserve state remain unchanged.

**Q: Can the reserve be "used up"?**
A: The reserve is not deducted like a quota — capital is withdrawn after every swap. But persistent one-way flow can convert one side entirely into the other token, requiring the owner to rebalance manually.

**Q: Can one hook serve multiple pools?**
A: No — each hook instance serves exactly one pool, which keeps accounting and settlement unambiguous. To serve another pool, deploy another hook through the factory; deployment is cheap and provenance is verifiable on-chain.

**Q: Can configuration be changed after deployment?**
A: Yes. The owner can call `setDistribution` to change ranges, `deposit` / `withdraw` to adjust reserves, and `setPoolLive` to pause or resume the pool — at any time, except mid-swap.

**Q: How does the user experience differ from a normal V4 pool?**
A: Users still swap through a compatible router. When the hook intervenes and the reserve is sufficient, available depth increases, typically reducing price impact for the same trade size; actual execution still depends on pool price, ranges, fees, reserve, and routing. When the hook is not quoting, routers should skip the pool, because it has no other liquidity.
