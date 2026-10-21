# Dual-source price feeds

These components combine a Chainlink primary with an optional Chainlink-compatible
fallback. Both sources must quote the same asset pair. Valid stored quotes remain
available during update outages, with their original timestamps, so consumers can
apply their own freshness policy.

## DualFeedPriceFeed

`DualFeedPriceFeed` inherits `ChainlinkBasePriceFeed`, reusing its source metadata,
ownership, heartbeat management, 18-decimal normalization and strict primary
aggregator bounds. The base contract only marks `latestRoundData` and
`setHeartbeat` as virtual; its own pricing and administration behaviour is
unchanged.

Constructor: `(owner, primary, fallback, heartbeat)`.

- `primary` must support the existing Chainlink aggregator/bounds interface.
- `fallback` accepts a Chainlink-compatible quote source, or the zero address.
- `heartbeat` is a positive freshness target in seconds, shared by both sources.
  The owner can update it through the existing heartbeat setter.
- Source decimals are read at deployment and must be between 0 and 36.

Selection:

1. Return a valid, fresh primary quote, including at the heartbeat boundary.
2. Otherwise return a valid, fresh fallback quote.
3. Otherwise return the newer valid stale quote, preferring the primary on a tie.
4. Revert with `NoValidPrice()` if neither source is usable.

Returned round metadata and timestamps belong to the selected source. Nonpositive
prices, zero/future update timestamps, failed/malformed reads, strict primary
bounds failures, normalization overflow and prices rounding to zero invalidate
only the affected source. An external `readSource` boundary lets `try/catch`
contain decoding and arithmetic failures while reusing the base feed's typed
calls and helpers. A healthy primary does not read the fallback.

There is no maintained local price cache. Both unreadable or invalid sources
still cause a revert. A valid single-source configuration retains stale
`updatedAt` instead of replacing it with zero.

## RedstoneStoredPriceFeed

This small adapter reads `getLastUpdateDetailsUnsafe(bytes32)` from an existing
RedStone multi-feed adapter. RedStone continues to verify signed updates before
storage. This reader adds no signature verification or update mechanism.

Constructor: `(adapter, dataFeedId, decimals, maxDataTimestampAhead, description)`.

| Parameter | Meaning |
| --- | --- |
| `adapter` | Deployed provider exposing the stored-details getter |
| `dataFeedId` | Exact `bytes32` identifier used by that provider |
| `decimals` | Decimal places of the stored value; no conversion occurs here |
| `maxDataTimestampAhead` | Allowed observation time ahead of publication, in seconds; zero allows no forward skew |
| `description` | Description of the configured asset pair |

The getter must return observation time in milliseconds, publication time in
seconds, and a positive stored value fitting `int256`. Missing timestamps and
future publication times are rejected. Forward observation skew is limited by
the constructor setting. `updatedAt` is the earlier of observation and
publication, so publishing an older observation cannot make it appear fresh.

The adapter has no read-time age expiry. It does not need the provider's expiry
value: the stored getter bypasses that check regardless of its configured
length. Switching freshness belongs to the selector's heartbeat; borrowing or
other action-specific freshness belongs to the consuming protocol. Adding an
expiry here would prevent retaining stale quotes during an extended outage.

## Integration

Configure source addresses, pair direction, feed identifiers, decimals and
clock tolerance for each deployment. Verify these against the exact provider
implementation, including its update validation. Provider upgrades can change
these assumptions.

The normalized selector can be used directly or as an input to existing
combining feeds. Immutable component addresses require new combining-feed
instances before changing an oracle registration. Review ownership, consumer
freshness thresholds and cached-price behaviour before adoption. A stale quote
preserves availability, not current market accuracy; restoring a fresh source
does not necessarily clear an existing pessimistic price cache.

## Tests

Run the deterministic feed and core market suites without an RPC endpoint:

```sh
forge test --match-contract '^(DualFeed|RedstoneStored|BorrowControllerTest$|OracleTest$|MarketTest$)' --evm-version shanghai
```

Tests cover primary/fallback priority, freshness boundaries, newest-stale
selection, metadata, provider/decoding failures, bounds, normalization,
ownership, configurable provider expiries, stored-value decimals and clock
skew. Integration tests cover existing Curve/bridge compositions, borrowing
rejection, liquidation settlement and recovery with a pessimistic daily low.
The local price publishers and Curve pool are mocks. Deployment and governance
changes still require a full fork simulation of the intended registrations.

The dedicated workflow uses Solidity 0.8.20 and Shanghai without RPC credentials.
The repository-wide compiler configuration is unchanged. The existing full fork
suite requires the `RPC_MAINNET` repository secret.
