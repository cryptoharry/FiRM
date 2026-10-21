// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

contract DualFeedSourceMock {
    uint8 public immutable decimals;
    string public description = "ETH / USD";
    int256 public answer;
    uint256 public updatedAt;
    uint80 public roundId = 7;
    bool public failRead;
    bool public failAggregator;
    bool public failMin;
    bool public failMax;
    int192 internal minimum = 1;
    int192 internal maximum = type(int192).max;

    constructor(uint8 _decimals) {
        decimals = _decimals;
    }

    function setRound(int256 _answer, uint256 _updatedAt) external {
        answer = _answer;
        updatedAt = _updatedAt;
    }

    function setRoundId(uint80 id) external {
        roundId = id;
    }

    function setFailRead(bool fail) external {
        failRead = fail;
    }

    function setBounds(int192 low, int192 high) external {
        minimum = low;
        maximum = high;
    }

    function setFailures(bool aggregator_, bool min_, bool max_) external {
        failAggregator = aggregator_;
        failMin = min_;
        failMax = max_;
    }

    function aggregator() external view returns (address) {
        require(!failAggregator, "Aggregator failed");
        return address(this);
    }

    function minAnswer() external view returns (int192) {
        require(!failMin, "Minimum failed");
        return minimum;
    }

    function maxAnswer() external view returns (int192) {
        require(!failMax, "Maximum failed");
        return maximum;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!failRead, "Feed failed");
        return (roundId, answer, updatedAt, updatedAt, roundId);
    }
}

contract RedstoneAdapterMock {
    uint256 public dataMilliseconds;
    uint256 public publishedAt;
    uint256 public value;
    bool public failRead;

    function set(uint256 data_, uint256 published_, uint256 value_) external {
        dataMilliseconds = data_;
        publishedAt = published_;
        value = value_;
    }

    function setFailRead(bool fail) external {
        failRead = fail;
    }

    function getLastUpdateDetailsUnsafe(bytes32) external view returns (uint256, uint256, uint256) {
        require(!failRead, "Adapter failed");
        return (dataMilliseconds, publishedAt, value);
    }

    function getLastUpdateDetails(bytes32) external view returns (uint256, uint256, uint256) {
        require(!failRead, "Adapter failed");
        require(value > 0 && publishedAt + 30 hours > block.timestamp, "Redstone expired");
        return (dataMilliseconds, publishedAt, value);
    }
}

contract ExpiringRedstoneFeedMock {
    uint8 public constant decimals = 8;
    RedstoneAdapterMock public immutable adapter;

    constructor(RedstoneAdapterMock adapter_) {
        adapter = adapter_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        (, uint256 timestamp, uint256 value) = adapter.getLastUpdateDetails(bytes32("ETH"));
        return (1, int256(value), timestamp, timestamp, 1);
    }
}

contract DualFeedCurvePoolMock {
    address public immutable asset;
    uint256 public price = 0.005 ether;
    uint256 public fee = 2e8;

    constructor(address asset_) {
        asset = asset_;
    }

    function coins(uint256 index) external view returns (address) {
        return index == 1 ? asset : address(0x1234);
    }

    function price_oracle() external view returns (uint256) {
        return price;
    }
}

contract DualFeedInvTokenMock {
    function symbol() external pure returns (string memory) {
        return "INV";
    }
}
