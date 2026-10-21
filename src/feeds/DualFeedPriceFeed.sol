// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ChainlinkBasePriceFeed} from "src/feeds/ChainlinkBasePriceFeed.sol";
import {IChainlinkFeed} from "src/interfaces/IChainlinkFeed.sol";

/// @notice Chainlink-primary feed that retains the newest valid quote during update outages.
/// @dev Both sources must quote the same pair. Timestamps retain the selected quote's age.
contract DualFeedPriceFeed is ChainlinkBasePriceFeed {
    error NoValidPrice();

    struct RoundData {
        uint80 roundId;
        int256 answer;
        uint256 startedAt;
        uint256 updatedAt;
        uint80 answeredInRound;
    }

    constructor(address _owner, address _primary, address _fallback, uint256 _heartbeat)
        ChainlinkBasePriceFeed(_owner, _primary, _fallback, _heartbeat)
    {
        require(_owner != address(0), "Invalid owner");
        require(_primary != _fallback, "Identical sources");
        require(_heartbeat > 0, "Invalid heartbeat");
        require(assetToUsdDecimals <= 36 && assetToUsdFallbackDecimals <= 36, "Unsupported decimals");
    }

    function latestRoundData() public view override returns (uint80, int256, uint256, uint256, uint80) {
        RoundData memory primary = _read(false);
        if (primary.updatedAt != 0 && _isFresh(primary.updatedAt)) return _result(primary);

        RoundData memory secondary = _read(true);
        if (secondary.updatedAt != 0 && _isFresh(secondary.updatedAt)) return _result(secondary);

        // A failed read has updatedAt == 0. Equal valid timestamps prefer the primary.
        if (primary.updatedAt != 0 && primary.updatedAt >= secondary.updatedAt) return _result(primary);
        if (secondary.updatedAt != 0) return _result(secondary);
        revert NoValidPrice();
    }

    function setHeartbeat(uint256 newHeartbeat) public override {
        require(newHeartbeat > 0, "Invalid heartbeat");
        super.setHeartbeat(newHeartbeat);
    }

    /// @dev External boundary lets _read catch decoding, bounds and normalization failures
    /// as well as provider reverts, while reusing the base feed's typed calls and helpers.
    function readSource(bool useFallback) external view returns (RoundData memory data) {
        IChainlinkFeed feed = useFallback ? assetToUsdFallback : assetToUsd;
        (data.roundId, data.answer, data.startedAt, data.updatedAt, data.answeredInRound) = feed.latestRoundData();
        if (data.answer <= 0 || data.updatedAt == 0 || data.updatedAt > block.timestamp) revert NoValidPrice();
        if (!useFallback && isPriceOutOfBounds(data.answer, feed)) revert NoValidPrice();
        data.answer = normalizePrice(data.answer, useFallback ? assetToUsdFallbackDecimals : assetToUsdDecimals);
        if (data.answer <= 0) revert NoValidPrice();
    }

    function _read(bool useFallback) internal view returns (RoundData memory data) {
        if (useFallback && !hasFallback()) return data;
        try this.readSource(useFallback) returns (RoundData memory result) {
            return result;
        } catch {}
    }

    function _isFresh(uint256 updatedAt) internal view returns (bool) {
        return block.timestamp - updatedAt <= assetToUsdHeartbeat;
    }

    function _result(RoundData memory data) internal pure returns (uint80, int256, uint256, uint256, uint80) {
        return (data.roundId, data.answer, data.startedAt, data.updatedAt, data.answeredInRound);
    }
}
