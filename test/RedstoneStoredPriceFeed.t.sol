// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {RedstoneStoredPriceFeed} from "src/feeds/RedstoneStoredPriceFeed.sol";
import {RedstoneAdapterMock} from "test/mocks/DualFeedMocks.sol";

contract RedstoneStoredPriceFeedTest is Test {
    RedstoneAdapterMock adapter;
    RedstoneStoredPriceFeed feed;

    function setUp() public {
        vm.warp(1000 days);
        adapter = new RedstoneAdapterMock();
        adapter.set(block.timestamp * 1000, block.timestamp, 2000e8);
        feed = new RedstoneStoredPriceFeed(address(adapter), bytes32("ETH"), "ETH / USD (stored RedStone)");
    }

    function test_retainsStoredPriceBeforeAtAndAfterThirtyHours() public {
        uint256 timestamp = block.timestamp;
        vm.warp(timestamp + 30 hours - 1);
        adapter.getLastUpdateDetails(bytes32("ETH"));
        _assertQuote(2000e8, timestamp);
        vm.warp(timestamp + 30 hours);
        vm.expectRevert("Redstone expired");
        adapter.getLastUpdateDetails(bytes32("ETH"));
        _assertQuote(2000e8, timestamp);
        vm.warp(timestamp + 30 hours + 1);
        _assertQuote(2000e8, timestamp);
        vm.warp(timestamp + 90 days);
        _assertQuote(2000e8, timestamp);
    }

    function test_publicationCannotRefreshOldObservation() public {
        adapter.set((block.timestamp - 2 hours) * 1000 + 999, block.timestamp, 2000e8);
        _assertQuote(2000e8, block.timestamp - 2 hours);
    }

    function test_allowedForwardClockSkewUsesPublicationTime() public {
        adapter.set((block.timestamp + 60) * 1000, block.timestamp, 2000e8);
        _assertQuote(2000e8, block.timestamp);
    }

    function test_excessiveForwardClockSkewIsRejected() public {
        adapter.set((block.timestamp + 61) * 1000, block.timestamp, 2000e8);
        _expectInvalid();
    }

    function test_futurePublicationIsRejected() public {
        adapter.set(block.timestamp * 1000, block.timestamp + 1, 2000e8);
        _expectInvalid();
    }

    function test_zeroObservationAndPublicationAreRejected() public {
        adapter.set(0, block.timestamp, 2000e8);
        _expectInvalid();
        adapter.set(block.timestamp * 1000, 0, 2000e8);
        _expectInvalid();
    }

    function test_zeroAndOverflowingValuesAreRejected() public {
        adapter.set(block.timestamp * 1000, block.timestamp, 0);
        _expectInvalid();
        adapter.set(block.timestamp * 1000, block.timestamp, uint256(type(int256).max) + 1);
        _expectInvalid();
    }

    function test_readFailurePropagatesForSelectorToHandle() public {
        adapter.setFailRead(true);
        vm.expectRevert("Adapter failed");
        feed.latestRoundData();
    }

    function test_usesConfiguredDataFeedId() public {
        RedstoneStoredPriceFeed btc = new RedstoneStoredPriceFeed(address(adapter), bytes32("BTC"), "BTC / USD");
        vm.expectCall(address(adapter), abi.encodeWithSignature("getLastUpdateDetailsUnsafe(bytes32)", bytes32("BTC")));
        btc.latestRoundData();
    }

    function _expectInvalid() internal {
        vm.expectRevert(RedstoneStoredPriceFeed.InvalidStoredPrice.selector);
        feed.latestRoundData();
    }

    function _assertQuote(int256 value, uint256 timestamp) internal view {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            feed.latestRoundData();
        assertEq(roundId, 1);
        assertEq(answeredInRound, 1);
        assertEq(answer, value);
        assertEq(startedAt, timestamp);
        assertEq(updatedAt, timestamp);
        assertEq(feed.latestAnswer(), answer);
        assertEq(feed.decimals(), 8);
    }
}
