# Dual-source USD feeds

FiRM's current ETH/USD and BTC/USD `ChainlinkBasePriceFeed` instances select
RedStone when Chainlink is stale. RedStone's current read interface reverts when
its last publication reaches 30 hours. If Chainlink remains stale, that revert
propagates through WETH, INV and WBTC pricing and prevents liquidations.

This change provides replacement components. It does not deploy contracts or
change any live market, oracle registration or controller threshold.

## Components and selection

`RedstoneStoredPriceFeed` reads `getLastUpdateDetailsUnsafe(bytes32)` on the
existing RedStone multi-feed adapter. Updates continue to be validated by
RedStone before storage; the replacement removes only the read-time expiry.
It rejects missing/zero values, values exceeding `int256`, missing timestamps,
future publication times, and signed data more than one minute ahead of its
publication. That forward tolerance matches the currently deployed adapter.
Its eight-decimal output is specific to the ETH/USD and BTC/USD records.

The reported timestamp is the earlier of the signed data timestamp (milliseconds
converted to seconds) and the publication timestamp. A delayed publication
cannot make an old observation appear fresh. Age alone does not cause a revert.

`DualFeedPriceFeed` accepts a Chainlink primary and a Chainlink-compatible
fallback, and normalizes both to 18 decimals. Both use the same configurable
freshness target:

1. Use a valid, fresh Chainlink quote, including at the heartbeat boundary.
2. Otherwise use a valid, fresh fallback quote.
3. Otherwise use the newer valid stale quote, preferring Chainlink on a tie.
4. Revert with `NoValidPrice()` if neither source is usable.

Each result retains the selected quote's metadata and timestamp. The selector
never marks old data fresh or replaces its timestamp with zero. Nonpositive
prices, zero/future update timestamps, malformed responses, normalization
overflow, and prices rounding down to zero are not candidates. Primary
validation preserves the existing strict Chainlink `minAnswer`/`maxAnswer`
checks. Failure to read the primary or its bounds invalidates only that source;
a failed fallback does not prevent using a valid stale primary. Consequently,
the primary must support Chainlink's aggregator and bounds interface.

A healthy primary is read without calling the fallback. There is no local
last-good-price cache. If both providers become unreadable or invalid, this
implementation deliberately does not invent a valuation.

## Mainnet wiring

The following configuration was checked at Ethereum block 26,234,376 on
20 October 2026. Recheck sources, proxy implementations and parameters before
deployment. RedStone's adapter is upgradeable; monitor changes to its interface,
decimals, timestamp semantics, data IDs and update validation.

| Component | Address / identifier |
| --- | --- |
| Chainlink ETH/USD primary | `0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419` |
| Chainlink BTC/USD primary | `0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c` |
| RedStone multi-feed adapter | `0xd72a6ba4a87ddb33e801b3f1c7750b2d0911fc6c` |
| ETH data ID | `bytes32("ETH")`, not a hash |
| BTC data ID | `bytes32("BTC")`, not a hash |
| Existing WBTC/BTC normalized component | `0x435419607191f1c1c6809e01bb5c38311957c6a8` |
| INV/WETH Curve pool | `0xdcd90d866ff9636e5a04768825d05d27b3fb19ec` |
| FiRM pessimistic oracle | `0xabe146cf570fd27ddd985895ce9b138a7110cce8` |

Deployment and governance preparation:

1. Deploy an ETH stored-price adapter and a BTC stored-price adapter, using the
   data IDs above. Verify the stored records are eight-decimal USD quotes.
2. Deploy ETH/USD and BTC/USD selectors using the respective Chainlink proxies
   and stored-price adapters. Set the intended owner and freshness target
   explicitly. The replaced USD components currently use 3,660 seconds.
3. Deploy a new `DynamicFeeCurveFeed` for INV with the new ETH/USD selector,
   the existing pool, INV token and governance. Preserve the existing `maxFee`
   and governance configuration after rechecking them.
4. Deploy a new `ChainlinkBridgeAssetFeed` for WBTC using the existing normalized
   WBTC/BTC component and the new BTC/USD selector. Preserve the existing ratio
   direction (`bridgeAssetDenominator`).
5. Prepare `Oracle.setFeed` updates: WETH to the ETH/USD selector; INV to its new
   Curve feed; WBTC to its new bridge feed. Preserve collateral token decimals
   (18, 18 and 8 respectively). Those are token decimals, not feed decimals.
6. Test the complete proposed registrations against existing positions and
   pessimistic-oracle cache state before governance execution.

The existing combining feeds store their component addresses immutably, so
changing the source file cannot update those deployed contracts. Replacement
feed deployments and oracle registration updates are required. Market contracts,
escrows, debts and borrower positions do not need migration for these updates.

## Borrowing and recovery

The controller continues to enforce borrowing freshness using the selected
timestamp. At the checked block, INV's borrowing threshold was 3,660 seconds;
WETH and WBTC used 86,460 seconds. The selector's switching target and the
controller's borrowing threshold are separate settings. This PR does not change
them onchain. A WBTC review must consider the different update schedules of its
WBTC/BTC and BTC/USD legs; the composite still reports the older leg's timestamp.

An old quote keeps pricing callable but does not guarantee accurate or profitable
liquidations. Freshness alone does not establish accuracy either. A fallback is
a second trusted source, not a quorum or independent agreement check. Neither
source protects against every shared market or chain failure. Prolonged outages
still require monitoring and an incident response.

Recovery restores Chainlink priority, but an already-recorded pessimistic daily
low is not cleared by switching feeds. Its existing lookback still applies.

## Tests

Run the deterministic feed and core market suites without an RPC endpoint:

```sh
forge test --match-contract '^(DualFeed|RedstoneStored|BorrowControllerTest$|OracleTest$|MarketTest$)' --evm-version shanghai
```

The dedicated CI job uses Solidity 0.8.20 and the Shanghai EVM target. The
repository-wide compiler configuration is unchanged. The existing full workflow
also runs fork suites that require the `RPC_MAINNET` repository secret; those
suites fail at setup if the RPC URL is missing.

Tests cover source failures and malformed responses, primary bounds, decimal
normalization, freshness boundaries, newest-stale selection and metadata,
ownership, RedStone expiry and observation age, INV's Curve/fee composition,
WBTC's older-component timestamp, controller borrowing rejection, settlement
through the real local Market/Oracle/DBR/escrow contracts, and recovery with an
existing daily-low cache. Upstream price publishers and the Curve pool are mocks
in these local tests. These are not mainnet transaction-fork tests or a completed
deployment/governance simulation.

Validation completed for this change: 42 new tests (including 256 fuzz cases)
and 95 existing Market, Oracle and BorrowController tests passed with Solidity
0.8.20 and the Shanghai EVM target.

Ten read-only Multicall3 control/replacement scenarios also passed at Ethereum
block 26,234,376, using injected replacement code and hypothetical source quotes
with native RedStone, Curve, combining-feed and controller contracts. These
checks covered both-stale selection, either provider being unreadable, and both
being unreadable. They were state overrides, not a live outage or a complete
deployment/governance simulation.

Tracking: https://maestro.inverse.finance/boards/2/tasks/419
