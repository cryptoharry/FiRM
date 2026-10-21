// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IRedstoneStoredAdapter {
    function getLastUpdateDetailsUnsafe(bytes32 dataFeedId)
        external
        view
        returns (uint256 dataTimestampMilliseconds, uint256 publicationTimestamp, uint256 value);
}

/// @notice Reads the last stored eight-decimal RedStone ETH/USD or BTC/USD quote.
/// @dev Removes the provider's read-time expiry only. Signed updates are still
/// validated by RedStone before storage. Consumers must enforce their own age policy.
contract RedstoneStoredPriceFeed {
    error InvalidStoredPrice();

    IRedstoneStoredAdapter public immutable adapter;
    bytes32 public immutable dataFeedId;
    uint8 public constant decimals = 8;
    // Matches the current adapter's allowed forward clock skew at publication.
    uint256 public constant MAX_DATA_TIMESTAMP_AHEAD = 1 minutes;
    string public description;

    constructor(address _adapter, bytes32 _dataFeedId, string memory _description) {
        require(_adapter != address(0) && _dataFeedId != bytes32(0), "Invalid source");
        adapter = IRedstoneStoredAdapter(_adapter);
        dataFeedId = _dataFeedId;
        description = _description;
    }

    function latestRoundData() public view returns (uint80, int256, uint256, uint256, uint80) {
        (uint256 dataMilliseconds, uint256 publishedAt, uint256 value) = adapter.getLastUpdateDetailsUnsafe(dataFeedId);
        uint256 observedAt = dataMilliseconds / 1000;
        if (
            value == 0 || value > uint256(type(int256).max) || observedAt == 0 || publishedAt == 0
                || publishedAt > block.timestamp
                || (observedAt > publishedAt && observedAt - publishedAt > MAX_DATA_TIMESTAMP_AHEAD)
        ) revert InvalidStoredPrice();

        // Publication must never make an older observation appear fresh. When
        // signed data is slightly ahead of the block clock, use publication time.
        uint256 updatedAt = observedAt < publishedAt ? observedAt : publishedAt;
        return (1, int256(value), updatedAt, updatedAt, 1);
    }

    function latestAnswer() external view returns (int256) {
        (, int256 answer,,,) = latestRoundData();
        return answer;
    }
}
