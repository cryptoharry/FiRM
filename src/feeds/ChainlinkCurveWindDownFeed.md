# ChainlinkCurveWindDownFeed

A coin-0 variant of `ChainlinkCurveFeed` for Curve StableSwap pools whose EMA input
is capped at `2e18`. Addresses, the reference-asset oracle index and token description
are not tied to any particular asset. For nonzero target coin indices, continue to
use `ChainlinkCurveFeed`: direct EMA pricing does not have the inverse-price floor.

## Pricing and activation

Before activation, the feed returns `baseUsdPrice * 1e18 / price_oracle(k)` and the
base feed's round metadata. Choose the base feed to match the pool's rate-normalized
units, as with `ChainlinkCurveFeed`; a vault share's USD price is not necessarily the
appropriate input. Deployment must verify that the pool uses the expected EMA cap.

The permissionless trigger is fixed at **EMA >= 1.9e18**. It is not configurable.
This corresponds to an inverse ratio of approximately 0.526316 reference units per
target unit; the absolute USD price depends on the base feed. This is a threshold
on the existing EMA, without an additional persistence or confirmation window.

- `canStartWindDown()` reports readiness, returning false if upstream calls fail.
- `previewWindDownStartPrice()` returns the starting USD price or a validation error.
- `startWindDown()` rechecks eligibility and permanently records the current price
  and timestamp. No caller-supplied price or timestamp is accepted.

Activation requires a positive, bounded base price, an EMA in range, and a nonzero,
nonfuture base timestamp no older than `activationMaxAge`. It is not possible to
activate from stale/failed dependencies. A prior successful readiness read does not
guarantee activation will still succeed when the transaction is included.

## Decay and borrowing

Once activated, the answer follows:

```
1 + floor((windDownStartPrice - 1) * remainingSeconds / windDownDuration)
```

At and after the endpoint the answer is `1`, one raw unit of an 18-decimal USD feed.
Both round timestamps are permanently zero. The real activation time is exposed
as `windDownStartedAt`. Round IDs are frozen metadata, not fresh Chainlink rounds.
There are no upstream calls after activation, so outages and apparent recoveries
cannot interrupt or reset the schedule. There is no owner, reset or parameter setter.

FiRM's borrow controller must have a nonzero, appropriate staleness threshold for
each consuming market. A zero feed timestamp then blocks borrowing immediately.
`CurveLPPessimisticFeed` forwards the minimum of its input timestamps, independently
of which input supplies the price. `CurveLPYearnV2Feed` preserves that timestamp.
FiRM's price oracle still reads the positive price for liquidation calculations.
Timestamp zero does not itself block collateral withdrawals.

This is an intentional wind-down valuation, not an estimate of market price.
Liquidations require unhealthy positions and profitable execution. A low endpoint
does not guarantee debt recovery: liquidity, bot availability, liquidation sizing,
and dust can leave residual debt. For LP integrations, the declining input affects
the whole LP through the minimum-price formula, and pool virtual price / vault
conversion rates still affect the final answer. Review these outcomes on a market
fork before deployment; positive upstream answers can also round to zero downstream.

## Deployment and keeper operation

Constructor arguments:

| Argument | Meaning |
| --- | --- |
| `_assetToUsd` | 18-decimal base USD feed |
| `_curvePool` | Compatible Curve pool, with the target at `coins[0]` |
| `_k` | Reference oracle index: 0 for `coins[1]`, 1 for `coins[2]`, etc. |
| `_duration` | Positive uint32 decay duration in seconds; e.g. 86400 for 24 hours |
| `_activationMaxAge` | Positive maximum base-feed age at activation; set for that feed's heartbeat |

The description is derived from `coins[0].symbol()`. `targetIndex()` is always zero.

A keeper polls `canStartWindDown()` and submits a standalone `startWindDown()`
transaction when eligible. Confirm its receipt and the `WindDownStarted` event.
Reading the feed does not activate it, and an activation rolled back with a failed
borrow does not persist. Until activation is mined, normal-mode timestamps continue
to apply. No further keeper updates are needed for the decay itself.

Existing LP and Yearn feed references are immutable. To use this component, deploy
replacement wrappers where needed and update FiRM's collateral-to-feed mappings
through governance. Relaunch requires another approved feed chain. Operator changes
to the borrow controller can still disable the timestamp safeguard independently.

## Tests

```
forge test --match-path test/feeds/ChainlinkCurveWindDownFeed.t.sol --evm-version shanghai -vv
```

The Shanghai override is needed because the existing repository configuration pairs
Solidity 0.8.20 with Cancun, which that compiler does not support. The repository
configuration is left unchanged.

Tests cover compatibility with `ChainlinkCurveFeed`, a different target token and
nonzero reference index, the fixed threshold boundary, freshness and dependency
failures, irreversible activation, fuzzed decay, extreme arithmetic, and timestamp
propagation through the actual LP feed, Yearn wrapper, Oracle and BorrowController.
These are local tests with mock pricing dependencies, not a market-fork simulation.
