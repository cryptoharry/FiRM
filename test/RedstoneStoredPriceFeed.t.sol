// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {RedstoneStoredPriceFeed} from "src/feeds/RedstoneStoredPriceFeed.sol";
import {DualFeedPriceFeed} from "src/feeds/DualFeedPriceFeed.sol";
import {RedstoneAdapterMock, DualFeedSourceMock} from "test/mocks/DualFeedMocks.sol";

contract RedstoneStoredPriceFeedTest is Test {
    RedstoneAdapterMock adapter;
    RedstoneStoredPriceFeed feed;

    function setUp() public {
        vm.warp(1000 days);
        adapter = new RedstoneAdapterMock(30 hours);
        adapter.set(block.timestamp * 1000, block.timestamp, 2000e8);
        feed = new RedstoneStoredPriceFeed(address(adapter), bytes32("ASSET"), 8, 1 minutes, "ASSET / QUOTE");
    }

    function test_retainsStoredPriceBeforeAtAndAfterProviderExpiry() public {
        uint256 timestamp = block.timestamp;
        uint256 expiry = adapter.maxDataStaleness();
        vm.warp(timestamp + expiry - 1);
        adapter.getLastUpdateDetails(bytes32("ASSET"));
        _assertQuote(2000e8, timestamp);
        vm.warp(timestamp + expiry);
        vm.expectRevert("Redstone expired");
        adapter.getLastUpdateDetails(bytes32("ASSET"));
        _assertQuote(2000e8, timestamp);
        vm.warp(timestamp + expiry + 1);
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
        RedstoneStoredPriceFeed other =
            new RedstoneStoredPriceFeed(address(adapter), bytes32("OTHER"), 18, 0, "OTHER / QUOTE");
        vm.expectCall(
            address(adapter), abi.encodeWithSignature("getLastUpdateDetailsUnsafe(bytes32)", bytes32("OTHER"))
        );
        other.latestRoundData();
    }

    function test_configurableForwardClockSkew() public {
        RedstoneStoredPriceFeed strict =
            new RedstoneStoredPriceFeed(address(adapter), bytes32("ASSET"), 8, 0, "ASSET / QUOTE");
        adapter.set((block.timestamp + 1) * 1000, block.timestamp, 2000e8);
        vm.expectRevert(RedstoneStoredPriceFeed.InvalidStoredPrice.selector);
        strict.latestRoundData();

        RedstoneStoredPriceFeed tolerant =
            new RedstoneStoredPriceFeed(address(adapter), bytes32("ASSET"), 8, 2 minutes, "ASSET / QUOTE");
        adapter.set((block.timestamp + 2 minutes) * 1000, block.timestamp, 2000e8);
        (,,, uint256 timestamp,) = tolerant.latestRoundData();
        assertEq(timestamp, block.timestamp);
        adapter.set((block.timestamp + 2 minutes + 1) * 1000, block.timestamp, 2000e8);
        vm.expectRevert(RedstoneStoredPriceFeed.InvalidStoredPrice.selector);
        tolerant.latestRoundData();
    }

    function testFuzz_retainsStoredQuoteAcrossConfiguredProviderExpiries(uint256 expiry) public {
        expiry = bound(expiry, 1, 7 days);
        RedstoneAdapterMock provider = new RedstoneAdapterMock(expiry);
        uint256 timestamp = block.timestamp;
        provider.set(timestamp * 1000, timestamp, 2e18);
        RedstoneStoredPriceFeed stored =
            new RedstoneStoredPriceFeed(address(provider), bytes32("ASSET"), 18, 0, "ASSET / QUOTE");
        vm.warp(timestamp + expiry);
        vm.expectRevert("Redstone expired");
        provider.getLastUpdateDetails(bytes32("ASSET"));
        (, int256 value,, uint256 updatedAt,) = stored.latestRoundData();
        assertEq(value, 2e18);
        assertEq(updatedAt, timestamp);
    }

    function testFuzz_configuredDecimalsAreNormalizedBySelector(uint8 sourceDecimals) public {
        sourceDecimals = uint8(bound(sourceDecimals, 0, 36));
        adapter.set(block.timestamp * 1000, block.timestamp, 2 * 10 ** sourceDecimals);
        RedstoneStoredPriceFeed stored =
            new RedstoneStoredPriceFeed(address(adapter), bytes32("ASSET"), sourceDecimals, 0, "ASSET / QUOTE");
        DualFeedSourceMock primary = new DualFeedSourceMock(8);
        primary.setFailRead(true);
        DualFeedPriceFeed selector = new DualFeedPriceFeed(address(this), address(primary), address(stored), 1 hours);
        assertEq(stored.decimals(), sourceDecimals);
        assertEq(selector.latestAnswer(), 2e18);
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
