// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ICurvePool} from "src/interfaces/ICurvePool.sol";
import {IChainlinkBasePriceFeed} from "src/interfaces/IChainlinkFeed.sol";
import {IERC20} from "src/interfaces/IERC20.sol";

/// @notice Coin-0 USD feed with an irreversible, permissionless liquidation wind-down.
/// @dev For StableSwap pools with a 2e18 capped EMA, pricing coins[0] by inversion.
///      As with ChainlinkCurveFeed, select the base USD feed to match the pool's rate-normalized units.
///      Use ChainlinkCurveFeed for nonzero target indices; their direct EMA has no downside floor.
///      Before activation: base USD price * 1e18 / Curve EMA.
///      After activation: fixed starting USD price decays to 1 raw feed unit; timestamps are zero.
///      Activation is permissionless at EMA >= 1.9e18, without a persistence window.
///      Fund this feed with Ethereum mainnet DOLA before activation to offer a one-time bounty.
///      The caller receives the full balance in the activation transaction, including a zero transfer.
///      There is no rescue function; DOLA sent after activation cannot be claimed.
///      Consuming FiRM markets must enable the borrow controller's staleness check.
contract ChainlinkCurveWindDownFeed {
    uint256 public constant WAD = 1e18;
    uint256 public constant EMA_CAP = 2e18;
    uint256 public constant WIND_DOWN_TRIGGER_EMA = 1.9e18;
    uint256 public constant TERMINAL_PRICE = 1;
    uint256 public constant targetIndex = 0;
    IERC20 public constant dola = IERC20(0x865377367054516e17014CcdED1e7d814EDC9ce4);

    IChainlinkBasePriceFeed public immutable assetToUsd;
    ICurvePool public immutable curvePool;
    uint256 public immutable assetOrTargetK;
    uint32 public immutable windDownDuration;
    uint256 public immutable activationMaxAge;
    string public description;

    bool public windDownStarted;
    uint256 public windDownStartedAt;
    uint256 public windDownStartPrice;
    uint80 public windDownRoundId;
    uint80 public windDownAnsweredInRound;

    error InvalidConfiguration();
    error InvalidBasePrice();
    error InvalidEma();
    error InvalidTimestamp();
    error StaleActivationPrice();
    error TriggerNotReached();
    error WindDownAlreadyStarted();
    error DolaTransferFailed();

    event WindDownStarted(
        address indexed caller, uint256 startedAt, uint256 startPrice, uint256 triggerEma, uint256 duration
    );
    event WindDownRewardPaid(address indexed caller, uint256 amount);

    struct Round {
        uint80 roundId;
        int256 answer;
        uint256 startedAt;
        uint256 updatedAt;
        uint80 answeredInRound;
    }

    /// @param _assetToUsd 18-decimal USD base feed for the asset represented by oracle index _k.
    /// @param _curvePool Curve pool with the priced target asset at coin index zero.
    /// @param _k Oracle index: 0 represents coins[1], 1 represents coins[2], etc.
    /// @param _duration Seconds from activation until the terminal price.
    /// @param _activationMaxAge Maximum age of the base-feed timestamp at activation.
    constructor(address _assetToUsd, address _curvePool, uint256 _k, uint32 _duration, uint256 _activationMaxAge) {
        if (_assetToUsd.code.length == 0 || _curvePool.code.length == 0 || _duration == 0 || _activationMaxAge == 0) {
            revert InvalidConfiguration();
        }
        if (IChainlinkBasePriceFeed(_assetToUsd).decimals() != 18) revert InvalidConfiguration();

        assetToUsd = IChainlinkBasePriceFeed(_assetToUsd);
        curvePool = ICurvePool(_curvePool);
        assetOrTargetK = _k;
        windDownDuration = _duration;
        activationMaxAge = _activationMaxAge;
        // Check that the selected oracle index is populated and infer the target description.
        if (curvePool.coins(_k + 1) == address(0)) revert InvalidConfiguration();
        description = string(abi.encodePacked(IERC20(curvePool.coins(0)).symbol(), " / USD"));
    }

    /// @notice Keeper readiness check. Returns false for dependency failures or invalid data.
    /// @dev A successful check does not guarantee a later transaction will succeed.
    function canStartWindDown() external view returns (bool) {
        if (windDownStarted) return false;
        try this.previewWindDownStartPrice() returns (uint256) {
            return true;
        } catch {
            return false;
        }
    }

    /// @notice Returns the starting USD price if activation is currently permitted; otherwise reverts.
    /// @dev Shares the exact eligibility checks used by startWindDown(). Does not record state.
    function previewWindDownStartPrice() external view returns (uint256) {
        (Round memory round,) = _activationRound();
        return uint256(round.answer);
    }

    /// @notice Permanently activates decay and immediately pays the caller this feed's entire DOLA balance.
    /// @dev Anyone may call; price and time cannot be supplied. Zero-balance activation is supported.
    /// @dev A rejected borrowing transaction cannot be used to persist activation: its state
    ///      changes would revert too. The keeper should submit this as a separate transaction.
    function startWindDown() external {
        (Round memory round, uint256 ema) = _activationRound();
        windDownStarted = true;
        windDownStartedAt = block.timestamp;
        windDownStartPrice = uint256(round.answer);
        windDownRoundId = round.roundId;
        windDownAnsweredInRound = round.answeredInRound;
        emit WindDownStarted(msg.sender, block.timestamp, uint256(round.answer), ema, windDownDuration);

        // Finalize activation before interacting with DOLA. Its transfer supports zero amounts.
        uint256 reward = dola.balanceOf(address(this));
        if (!dola.transfer(msg.sender, reward)) revert DolaTransferFailed();
        emit WindDownRewardPaid(msg.sender, reward);
    }

    function latestRoundData()
        public
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        if (windDownStarted) {
            // Zero timestamps intentionally signal unusable-for-borrowing data to FiRM.
            // No upstream calls: outages and apparent recoveries cannot interrupt decay.
            return (windDownRoundId, int256(_decayedPrice()), 0, 0, windDownAnsweredInRound);
        }
        (Round memory round,) = _liveRound();
        return (round.roundId, round.answer, round.startedAt, round.updatedAt, round.answeredInRound);
    }

    function latestAnswer() external view returns (int256) {
        (, int256 answer,,,) = latestRoundData();
        return answer;
    }

    function decimals() public pure returns (uint256) {
        return 18;
    }

    function _activationRound() internal view returns (Round memory round, uint256 ema) {
        if (windDownStarted) revert WindDownAlreadyStarted();
        (round, ema) = _liveRound();
        if (ema < WIND_DOWN_TRIGGER_EMA) revert TriggerNotReached();
        if (round.updatedAt == 0 || round.updatedAt > block.timestamp) revert InvalidTimestamp();
        if (block.timestamp - round.updatedAt > activationMaxAge) revert StaleActivationPrice();
    }

    function _liveRound() internal view returns (Round memory round, uint256 ema) {
        (round.roundId, round.answer, round.startedAt, round.updatedAt, round.answeredInRound) =
            assetToUsd.latestRoundData();
        // Bound the multiplication and reject nonpositive prices before unsigned conversion.
        if (round.answer <= 0 || uint256(round.answer) > uint256(type(int256).max) / WAD) {
            revert InvalidBasePrice();
        }
        ema = curvePool.price_oracle(assetOrTargetK);
        if (ema == 0 || ema > EMA_CAP) revert InvalidEma();
        uint256 price = uint256(round.answer) * WAD / ema;
        if (price == 0 || price > uint256(type(int256).max)) revert InvalidBasePrice();
        round.answer = int256(price);
        // Preserve upstream timestamps in normal mode. Downstream FiRM enforces staleness.
    }

    function _decayedPrice() internal view returns (uint256) {
        uint256 elapsed = block.timestamp - windDownStartedAt;
        if (elapsed >= windDownDuration) return TERMINAL_PRICE;
        uint256 remaining = windDownDuration - elapsed;
        uint256 span = windDownStartPrice - TERMINAL_PRICE;
        // Safe: activation EMA > 1e18 and base answer <= int256.max / 1e18,
        // so span <= int256.max / 1e18; remaining <= uint32.max.
        return TERMINAL_PRICE + span * remaining / windDownDuration;
    }
}
