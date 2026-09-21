// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ICurvePool} from "src/interfaces/ICurvePool.sol";
import {IChainlinkBasePriceFeed} from "src/interfaces/IChainlinkFeed.sol";
import {IERC20} from "src/interfaces/IERC20.sol";

/// @notice Coin-0 USD feed with permissionless liquidation wind-down and RWG-controlled recovery.
/// @dev For StableSwap pools with a 2e18 capped EMA, pricing coins[0] by inversion.
///      As with ChainlinkCurveFeed, select the base USD feed to match the pool's rate-normalized units.
///      Use ChainlinkCurveFeed for nonzero target indices; their direct EMA has no downside floor.
///      Before activation: base USD price * 1e18 / Curve EMA.
///      After activation: fixed starting USD price decays to 1 raw feed unit; timestamps are zero.
///      Activation is permissionless at EMA >= 1.9e18, without a persistence window or timestamp check.
///      The RWG address fixed at deployment can stop wind-down and restore live pricing and timestamps.
///      Fund this feed with Ethereum mainnet DOLA before activation to offer a caller reward.
///      The caller receives the full balance in the activation transaction, including a zero transfer.
///      There is no rescue function; DOLA is paid only when a wind-down is started.
///      Consuming FiRM markets must enable the borrow controller's staleness check.
contract ChainlinkCurveWindDownFeed {
    uint256 public constant WIND_DOWN_TRIGGER_EMA = 1.9e18;
    uint256 public constant TERMINAL_PRICE = 1;
    uint256 public constant targetIndex = 0;
    IERC20 public constant dola = IERC20(0x865377367054516e17014CcdED1e7d814EDC9ce4);

    IChainlinkBasePriceFeed public immutable assetToUsd;
    ICurvePool public immutable curvePool;
    uint256 public immutable assetOrTargetK;
    uint32 public immutable windDownDuration;
    address public immutable rwg;
    string public description;

    uint256 public windDownStartedAt;
    // A positive recorded price marks an active wind-down; RWG can clear it.
    uint256 public windDownStartPrice;

    error InvalidConfiguration();
    error InvalidBasePrice();
    error TriggerNotReached();
    error WindDownAlreadyStarted();
    error OnlyRWG();

    event WindDownStarted(
        address indexed caller,
        uint256 startedAt,
        uint256 startPrice,
        uint256 triggerEma,
        uint256 duration,
        uint256 reward
    );
    event WindDownStopped(address indexed caller);

    /// @param _assetToUsd 18-decimal USD base feed for the asset represented by oracle index _k.
    /// @param _curvePool Curve pool with the priced target asset at coin index zero.
    /// @param _k Oracle index: 0 represents coins[1], 1 represents coins[2], etc.
    /// @param _duration Seconds from activation until the terminal price.
    /// @param _rwg RWG multisig allowed to stop wind-down; fixed at deployment.
    constructor(address _assetToUsd, address _curvePool, uint256 _k, uint32 _duration, address _rwg) {
        assetToUsd = IChainlinkBasePriceFeed(_assetToUsd);
        if (assetToUsd.decimals() != 18 || _duration == 0 || _rwg == address(0)) revert InvalidConfiguration();
        curvePool = ICurvePool(_curvePool);
        assetOrTargetK = _k;
        windDownDuration = _duration;
        rwg = _rwg;
        // Check that the selected oracle index is populated and infer the target description.
        if (curvePool.coins(_k + 1) == address(0)) revert InvalidConfiguration();
        string memory coin = IERC20(curvePool.coins(targetIndex)).symbol();
        description = string(abi.encodePacked(coin, " / USD"));
    }

    /// @notice Whether the EMA permits activation and wind-down has not already started.
    /// @dev Only checks the trigger. Execution still needs a readable positive USD price and DOLA transfer.
    function canStartWindDown() external view returns (bool) {
        return windDownStartPrice == 0 && curvePool.price_oracle(assetOrTargetK) >= WIND_DOWN_TRIGGER_EMA;
    }

    /// @notice Activates decay and immediately pays the caller this feed's entire DOLA balance.
    /// @dev Anyone may call; price and time cannot be supplied. Zero-balance activation is supported.
    /// @dev A rejected borrowing transaction cannot be used to persist activation: its state
    ///      changes would revert too. The keeper should submit this as a separate transaction.
    function startWindDown() external {
        if (windDownStartPrice != 0) revert WindDownAlreadyStarted();
        uint256 ema = curvePool.price_oracle(assetOrTargetK);
        if (ema < WIND_DOWN_TRIGGER_EMA) revert TriggerNotReached();
        (, int256 price,,,) = latestRoundData();
        windDownStartedAt = block.timestamp;
        windDownStartPrice = uint256(price);

        // Finalize activation before interacting with DOLA. Its transfer supports zero amounts.
        uint256 reward = dola.balanceOf(address(this));
        dola.transfer(msg.sender, reward);
        emit WindDownStarted(msg.sender, block.timestamp, uint256(price), ema, windDownDuration, reward);
    }

    /// @notice RWG-only reset to live pricing, including after the terminal price is reached.
    /// @dev Does not clear FiRM's recorded daily lows. EMA >= 1.9e18 permits immediate reactivation.
    function stopWindDown() external {
        if (msg.sender != rwg) revert OnlyRWG();
        windDownStartPrice = 0;
        windDownStartedAt = 0;
        emit WindDownStopped(msg.sender);
    }

    function latestRoundData()
        public
        view
        returns (uint80 roundId, int256 usdPrice, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        if (windDownStartPrice != 0) {
            // Zero timestamps intentionally signal unusable-for-borrowing data to FiRM.
            // No upstream calls: outages and apparent recoveries cannot interrupt decay.
            uint256 elapsed = block.timestamp - windDownStartedAt;
            uint256 price = TERMINAL_PRICE;
            if (elapsed < windDownDuration) {
                // Safe: activation EMA >= 1.9e18 and checked signed pricing bounds the start price;
                // the remaining duration is at most uint32.max.
                price += (windDownStartPrice - TERMINAL_PRICE) * (windDownDuration - elapsed) / windDownDuration;
            }
            return (0, int256(price), 0, 0, 0);
        }
        int256 assetToUsdPrice;
        (roundId, assetToUsdPrice, startedAt, updatedAt, answeredInRound) = assetToUsd.latestRoundData();
        // Same coin-0 calculation as ChainlinkCurveFeed; Solidity checks signed overflow.
        usdPrice = (assetToUsdPrice * int256(10 ** decimals())) / int256(curvePool.price_oracle(assetOrTargetK));
        if (usdPrice <= 0) revert InvalidBasePrice();
        return (roundId, usdPrice, startedAt, updatedAt, answeredInRound);
    }

    function latestAnswer() external view returns (int256) {
        (, int256 latestPrice,,,) = latestRoundData();
        return latestPrice;
    }

    function decimals() public pure returns (uint256) {
        return 18;
    }
}
