# Permissionless Risk-Tranched Lending Protocol

A Solidity/Foundry lending protocol in the spirit of Aave v3, with one structural difference:
there is no risk committee. Any collateral market can be created permissionlessly, and every
lender individually chooses which collateral markets they'll lend against, at what maximum
borrow LTV, and at what liquidation LTV. Governance's role is reduced to three narrow,
asset-agnostic knobs (see below) instead of asset-by-asset listing and risk-parameter votes.

## Why this exists

Aave's risk committee curates which assets get listed and at what LTV/LT for the *entire*
shared pool. A WETH lender has no way to opt out of exposure to a newly-listed, correlated
collateral type that governance adds later — this is close to what happened in the rsETH
situation, where WETH suppliers ended up exposed to rsETH borrowers they never consciously
chose to lend to. This protocol makes that choice explicit and per-lender instead of collective
and governance-mediated.

## Core architecture

### Markets = (collateral token, oracle adapter)
Permissionless via `MarketFactory.createMarket`. The only gate: the oracle adapter's runtime
**codehash** must be on governance's allowlist (`ProtocolConfig.allowedAdapterCodehash`), and
the adapter must be hard-bound to the exact collateral token being listed
(`IOracleAdapter.token() == collateralToken`). This closes the obvious hole in "anyone can pick
any oracle" — attaching an attacker-controlled price feed to a legitimate token — while keeping
asset selection itself fully open. Governance allowlists *oracle adapter implementations* (a
one-time infra decision, "is this adapter design trustworthy"), not individual assets.

### Buckets = the lender's risk decision, Uniswap-v3-tick-style
A lender calls `LendingPool.supply(marketId, loanAsset, ltvBps, lltvBps, amount)`. This is the
entire risk-management surface of the protocol: which collateral, what maximum borrow LTV, what
liquidation LTV. LTV/LLTV are discretized into 1%-wide ticks (`BucketMath`, ticks 40%-95% for
LTV, up to 99% for LLTV) so that many lenders with the *same* choice pool into one fungible
bucket, and so a borrower can walk the ladder of buckets cheapest (lowest LTV, safest for
lenders) first -- exactly the "spectrum of available capital vs. LTV" the design is meant to
produce. Active ticks are tracked with a bitmap per `(loanAsset, marketId)` ladder and a
sub-bitmap per LTV tick, so `borrow()` only touches ticks that actually have liquidity.

### Draws = one well-defined, independently liquidatable unit
The hard problem with "cross-margin + individualized per-lender LTV" is that liquidation
becomes ambiguous the moment one debt position spans collateral backed by lenders with
different LLTVs. This protocol resolves it by having `borrow()` create a `Draw` -- a permanent
pairing of *a specific chunk of collateral* with *the specific bucket that backed it* -- every
time it taps a new `(market, ltvTick, lltvTick)` combination. A borrower's account can hold many
Draws simultaneously across many collateral markets (genuine cross-margin at the account level:
deposit WETH and WBTC, borrow against both), but each individual Draw is self-contained: its own
collateral, its own debt, its own LLTV, so liquidation is always well-defined and never requires
guessing which collateral should back which lender's shortfall. See `CrossMargin.t.sol` for the
account-level behavior this produces, including that a price crash in one market never touches a
draw backed by a different, uncorrelated market.

*Known v1 limitation:* because health is evaluated per-draw rather than on a single blended
position, a borrower with idle "free" collateral in market A cannot have it automatically
rescue a struggling draw in market B without an explicit top-up transaction. A `topUpDraw`-style
rebalancing extension is a natural v2 addition; it was deliberately left out of v1 to keep the
liquidation math provably simple.

### Interest rate model -- the one governance-tuned curve
Standard two-slope kinked model (`InterestRateModel.sol`), applied **independently to each
bucket's own utilization**. Governance sets base rate / slope1 / slope2 / kink **per loan asset
only** (`ProtocolConfig.setRateModel`) -- never per market, never per bucket. In practice,
because capital is already rationed across the LTV ladder (thin at high LTV, deep at low LTV),
the *bucket a borrower has to reach into* does most of the work of pricing risk; the kink mainly
absorbs demand shocks within whichever bucket is currently marginal. Listing a loan asset
(`initLoanAsset`) is permissionless and bootstraps conservative default curve parameters;
governance may retune afterward.

### Liquidation -- systemic Dutch auction, never lender-configurable
`LiquidationAuction.sol` implements a single, protocol-wide bonus curve that ramps from a small
starting bonus to a capped maximum over a fixed duration after a draw first crosses its
bucket's LLTV (`ProtocolConfig.liquidationParams`). This is deliberately **not** set per lender
or per bucket: a lender who chose a 95% LLTV bucket has almost no price cushion, and a bonus
fixed at that cushion would often be unprofitable for a keeper to act on once gas and slippage
are priced in -- in practice that means liquidations simply don't fire, and the "small haircut"
becomes real bad debt instead. Ramping the bonus over time means a draw's own shrinking cushion,
not a governance- or lender-set parameter, determines how much risk that lender bears; it
doesn't change *whether* a liquidator eventually finds it worth acting.

If a draw's collateral is exhausted before its debt is, `liquidate()` caps the liquidator's
seize at whatever collateral remains (never creates negative balances), and the draw persists
with zero collateral and outstanding debt. `LendingPool.socializeBadDebt` then lets anyone write
that remaining debt down against the **specific bucket** that backed it -- the loss is borne
only by lenders who explicitly opted into that exact `(market, ltvTick, lltvTick)` combination,
never by lenders in other buckets, markets, or loan assets. This is the risk-isolation property
the whole design is built around, made concrete in the accounting.

### Governance surface (intentionally the entire list)
1. Which oracle adapter *implementations* (by codehash) are trusted -- infra-level, one-time.
2. Base rate / slope1 / slope2 / kink, per loan asset.
3. The liquidation Dutch-auction curve (start bonus, max bonus, ramp duration) -- systemic.

Everything else -- which collaterals exist, which lenders back them, at what leverage, at what
liquidation threshold -- is fully permissionless and user-directed.

## Contract layout

```
src/
  interfaces/IOracleAdapter.sol       - price adapter interface, hard-bound to one token
  libraries/
    BucketMath.sol                    - LTV/LLTV tick discretization + validation
    MathLib.sol                       - share<->asset conversion with inflation-attack offset
    InterestRateModel.sol             - kinked rate model, per-bucket utilization
    LiquidationAuction.sol            - systemic Dutch-auction bonus curve
  governance/ProtocolConfig.sol       - the entire governance surface (see above)
  core/
    MarketFactory.sol                 - permissionless (collateral, oracle) market creation
    LendingPool.sol                   - buckets, draws, supply/borrow/repay/liquidate
  oracles/ChainlinkOracleAdapter.sol  - reference adapter implementation
  mocks/                              - MockERC20, MockOracleAdapter (tests only)
test/
  unit/          - BucketMath, MathLib, InterestRateModel, LiquidationAuction
  integration/   - SupplyBorrow, Liquidation, CrossMargin (full pool flows via Foundry)
  utils/TestBase.sol - shared fixture: deploys config/factory/pool, mints tokens, wires oracles
```

## A subtlety worth knowing if you extend this: codehash allowlisting and `immutable`

Both `ChainlinkOracleAdapter` and `MockOracleAdapter` deliberately avoid Solidity's `immutable`
keyword for constructor-supplied values (token address, feed address, staleness window).
`immutable` values are inlined directly into a contract's *runtime* bytecode, which means two
instances of the same adapter deployed with different constructor arguments end up with
different `codehash`. Since `ProtocolConfig` allowlists adapters by codehash specifically so one
audited implementation can back unlimited per-token instances without a fresh governance vote
each time, using `immutable` here would silently break that model -- every new token's adapter
would need its own allowlist entry again, reintroducing the asset-by-asset bottleneck this
protocol exists to avoid. Plain storage costs a little extra gas per price read; that trade-off
is intentional.

## Running

```bash
forge build
forge test -vv
```

Solc 0.8.26, `via_ir = true` (required -- bucket ladder + draw accounting is deep enough to hit
"stack too deep" without it).

## What's deliberately out of scope for this reference implementation

- Flash loans, e-mode-style category grouping, stable-rate borrowing.
- A `topUpDraw` / cross-collateral rescue mechanism (noted above).
- Protocol fee switch on interest (100% of interest currently accrues to suppliers).
- Gas-optimized tick iteration beyond the bitmap approach (fine up to ~100 ticks; a production
  system serving many simultaneous markets might want per-market bitmap sharding).
- A governance timelock/multisig wrapper around `ProtocolConfig` -- `AccessControl` is used as a
  minimal placeholder; production deployment should put a timelock behind `GOVERNANCE_ROLE`.
- Formal verification / audit. This is a scaffold that compiles and passes its test suite, not
  an audited, production-ready deployment.
