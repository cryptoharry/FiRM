// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IChainlinkFeed} from "src/interfaces/IChainlinkFeed.sol";

interface IDualFeedAggregator {
    function minAnswer() external view returns (int192);
    function maxAnswer() external view returns (int192);
}

/// @notice Chainlink-primary price feed with a Chainlink-compatible fallback.
/// @dev Both sources use the same freshness target. Age alone never invalidates
/// a quote: if neither is fresh, the newer valid quote is returned with its age.
contract DualFeedPriceFeed {
    error NoValidPrice();

    struct RoundData {
        uint80 roundId;
        int256 answer;
        uint256 startedAt;
        uint256 updatedAt;
        uint80 answeredInRound;
        bool valid;
    }

    IChainlinkFeed public immutable assetToUsd;
    IChainlinkFeed public immutable assetToUsdFallback;
    uint8 public immutable assetToUsdDecimals;
    uint8 public immutable assetToUsdFallbackDecimals;
    uint8 public constant decimals = 18;
    string public description;
    address public owner;
    address public pendingOwner;
    uint256 public assetToUsdHeartbeat;

    event NewHeartbeat(uint256 heartbeat);
    event NewPendingOwner(address pendingOwner);
    event NewOwner(address owner);

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    constructor(address _owner, address _assetToUsd, address _fallback, uint256 _heartbeat) {
        require(_owner != address(0), "Invalid owner");
        require(_assetToUsd != address(0) && _fallback != address(0), "Invalid source");
        require(_assetToUsd != _fallback, "Identical sources");
        require(_heartbeat > 0, "Invalid heartbeat");
        owner = _owner;
        assetToUsd = IChainlinkFeed(_assetToUsd);
        assetToUsdFallback = IChainlinkFeed(_fallback);
        assetToUsdDecimals = assetToUsd.decimals();
        assetToUsdFallbackDecimals = assetToUsdFallback.decimals();
        require(assetToUsdDecimals <= 36 && assetToUsdFallbackDecimals <= 36, "Unsupported decimals");
        assetToUsdHeartbeat = _heartbeat;
        description = assetToUsd.description();
    }

    function latestRoundData() public view returns (uint80, int256, uint256, uint256, uint80) {
        RoundData memory primary = _read(assetToUsd, assetToUsdDecimals, true);
        if (primary.valid && _isFresh(primary.updatedAt)) return _result(primary);

        RoundData memory secondary = _read(assetToUsdFallback, assetToUsdFallbackDecimals, false);
        if (secondary.valid && _isFresh(secondary.updatedAt)) return _result(secondary);

        // Prefer Chainlink on a tie. Neither zero/future timestamps nor failed
        // reads are candidates, even when the other source is also unavailable.
        if (primary.valid && (!secondary.valid || primary.updatedAt >= secondary.updatedAt)) {
            return _result(primary);
        }
        if (secondary.valid) return _result(secondary);
        revert NoValidPrice();
    }

    function latestAnswer() external view returns (int256) {
        (, int256 answer,,,) = latestRoundData();
        return answer;
    }

    function hasFallback() external pure returns (bool) {
        return true;
    }

    function setHeartbeat(uint256 heartbeat) external onlyOwner {
        require(heartbeat > 0, "Invalid heartbeat");
        assetToUsdHeartbeat = heartbeat;
        emit NewHeartbeat(heartbeat);
    }

    function setPendingOwner(address newOwner) external onlyOwner {
        pendingOwner = newOwner;
        emit NewPendingOwner(newOwner);
    }

    function acceptOwner() external {
        require(msg.sender == pendingOwner, "Only pending owner");
        owner = pendingOwner;
        pendingOwner = address(0);
        emit NewOwner(owner);
    }

    function _isFresh(uint256 updatedAt) internal view returns (bool) {
        // _read has already excluded future timestamps.
        return block.timestamp - updatedAt <= assetToUsdHeartbeat;
    }

    function _read(IChainlinkFeed feed, uint8 feedDecimals, bool checkBounds)
        internal
        view
        returns (RoundData memory data)
    {
        (bool success, bytes memory result) =
            address(feed).staticcall(abi.encodeWithSelector(IChainlinkFeed.latestRoundData.selector));
        if (!success || result.length < 160) return data;
        // Decode round IDs as full words first: malformed uint80 return values
        // must invalidate only this source, rather than revert during decoding.
        (uint256 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint256 answeredInRound) =
            abi.decode(result, (uint256, int256, uint256, uint256, uint256));
        if (roundId > type(uint80).max || answeredInRound > type(uint80).max) return data;
        if (answer <= 0 || updatedAt == 0 || updatedAt > block.timestamp) return data;
        if (checkBounds && !_withinPrimaryBounds(answer)) return data;
        int256 normalized = _normalize(answer, feedDecimals);
        if (normalized == 0) return data;
        data = RoundData(uint80(roundId), normalized, startedAt, updatedAt, uint80(answeredInRound), true);
    }

    /// @dev Preserve ChainlinkBasePriceFeed's strict primary bounds. A failure
    /// to read the aggregator or either bound makes only the primary unusable.
    function _withinPrimaryBounds(int256 answer) internal view returns (bool) {
        (bool success, uint256 aggregatorWord) = _readWord(address(assetToUsd), IChainlinkFeed.aggregator.selector);
        if (!success || aggregatorWord == 0 || aggregatorWord > type(uint160).max) return false;
        address aggregator = address(uint160(aggregatorWord));
        (bool minSuccess, uint256 minWord) = _readWord(aggregator, IDualFeedAggregator.minAnswer.selector);
        (bool maxSuccess, uint256 maxWord) = _readWord(aggregator, IDualFeedAggregator.maxAnswer.selector);
        int256 minimum = int256(minWord);
        int256 maximum = int256(maxWord);
        return minSuccess && maxSuccess && minimum >= type(int192).min && minimum <= type(int192).max
            && maximum >= type(int192).min && maximum <= type(int192).max && minimum < maximum && answer > minimum
            && answer < maximum;
    }

    function _readWord(address target, bytes4 selector) internal view returns (bool, uint256) {
        (bool success, bytes memory result) = target.staticcall(abi.encodeWithSelector(selector));
        if (!success || result.length < 32) return (false, 0);
        return (true, abi.decode(result, (uint256)));
    }

    function _normalize(int256 answer, uint8 feedDecimals) internal pure returns (int256) {
        if (feedDecimals > 18) return answer / int256(10 ** (feedDecimals - 18));
        uint256 scale = 10 ** (18 - feedDecimals);
        if (uint256(answer) > uint256(type(int256).max) / scale) return 0;
        return answer * int256(scale);
    }

    function _result(RoundData memory data) internal pure returns (uint80, int256, uint256, uint256, uint80) {
        return (data.roundId, data.answer, data.startedAt, data.updatedAt, data.answeredInRound);
    }
}
