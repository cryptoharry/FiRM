// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DualFeedPriceFeed} from "src/feeds/DualFeedPriceFeed.sol";
import {RedstoneStoredPriceFeed} from "src/feeds/RedstoneStoredPriceFeed.sol";
import {DynamicFeeCurveFeed} from "src/feeds/DynamicFeeCurveFeed.sol";
import {ChainlinkBridgeAssetFeed} from "src/feeds/ChainlinkBridgeAssetFeed.sol";
import {
    DualFeedSourceMock,
    RedstoneAdapterMock,
    DualFeedCurvePoolMock,
    DualFeedTokenMock
} from "test/mocks/DualFeedMocks.sol";

contract DualFeedCompositionTest is Test {
    DualFeedSourceMock primary;
    RedstoneAdapterMock adapter;
    DualFeedPriceFeed usd;

    function setUp() public {
        vm.warp(1000 days);
        primary = new DualFeedSourceMock(8);
        primary.setRound(2000e8, block.timestamp);
        adapter = new RedstoneAdapterMock(30 hours);
        adapter.set(block.timestamp * 1000, block.timestamp, 1900e8);
        RedstoneStoredPriceFeed stored =
            new RedstoneStoredPriceFeed(address(adapter), bytes32("ASSET"), 8, 1 minutes, "ASSET / QUOTE");
        usd = new DualFeedPriceFeed(address(this), address(primary), address(stored), 3660);
    }

    function test_curveCompositionPreservesCurveFeeAndSelectedAgeAfterExpiry() public {
        DualFeedTokenMock asset = new DualFeedTokenMock();
        DualFeedCurvePoolMock pool = new DualFeedCurvePoolMock(address(asset));
        DynamicFeeCurveFeed feed = new DynamicFeeCurveFeed(address(usd), address(pool), address(asset), address(this));
        (, int256 price,, uint256 timestamp,) = feed.latestRoundData();
        assertEq(price, 9.8e18); // 2000 QUOTE/BRIDGE * 0.005 BRIDGE/ASSET * 98%
        assertEq(timestamp, block.timestamp);

        vm.warp(block.timestamp + 1 minutes);
        adapter.set(block.timestamp * 1000, block.timestamp, 1900e8);
        uint256 fallbackTimestamp = block.timestamp;
        vm.warp(block.timestamp + adapter.maxDataStaleness());
        vm.expectRevert("Redstone expired");
        adapter.getLastUpdateDetails(bytes32("ASSET"));
        (, price,, timestamp,) = feed.latestRoundData();
        assertEq(price, 9.31e18);
        assertEq(timestamp, fallbackTimestamp);
        assertEq(feed.latestAnswer(), price);
        assertEq(feed.maxFee(), 2e8);
    }

    function test_bridgeCompositionRetainsOlderConversionLegTimestamp() public {
        primary.setRound(50000e8, block.timestamp);
        DualFeedSourceMock ratio = new DualFeedSourceMock(18);
        ratio.setRound(0.999e18, block.timestamp - 2 hours);
        ChainlinkBridgeAssetFeed feed = new ChainlinkBridgeAssetFeed(address(ratio), address(usd), true);
        (, int256 price,, uint256 timestamp,) = feed.latestRoundData();
        assertEq(price, 49950e18);
        assertEq(timestamp, block.timestamp - 2 hours);

        uint256 usdTimestamp = block.timestamp;
        vm.warp(block.timestamp + 40 hours);
        ratio.setRound(0.999e18, block.timestamp);
        adapter.set((usdTimestamp - 1) * 1000, usdTimestamp - 1, 49000e8);
        (, price,, timestamp,) = feed.latestRoundData();
        assertEq(price, 49950e18); // Chainlink's stale USD quote is newer.
        assertEq(timestamp, usdTimestamp); // The fresh ratio cannot refresh USD data.
        assertEq(feed.decimals(), 18);
    }
}
