// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DualFeedPriceFeed} from "src/feeds/DualFeedPriceFeed.sol";
import {ChainlinkBasePriceFeed} from "src/feeds/ChainlinkBasePriceFeed.sol";
import {DualFeedSourceMock} from "test/mocks/DualFeedMocks.sol";

contract DualFeedPriceFeedTest is Test {
    uint256 constant HEARTBEAT = 3660;
    DualFeedSourceMock primary;
    DualFeedSourceMock secondary;
    DualFeedPriceFeed feed;

    function setUp() public {
        vm.warp(1000 days);
        primary = new DualFeedSourceMock(8);
        secondary = new DualFeedSourceMock(8);
        primary.setRound(2000e8, block.timestamp);
        secondary.setRound(1900e8, block.timestamp);
        secondary.setRoundId(9);
        feed = new DualFeedPriceFeed(address(this), address(primary), address(secondary), HEARTBEAT);
    }

    function test_freshPrimaryHasPriorityEvenWithNewerFallback() public {
        primary.setRound(2000e8, block.timestamp - 10);
        _assertQuote(2000e18, block.timestamp - 10, 7);
    }

    function test_freshPrimaryDoesNotDependOnFallbackRead() public {
        secondary.setFailRead(true);
        _assertQuote(2000e18, block.timestamp, 7);
    }

    function test_primaryFreshAtHeartbeatThenFallsBack() public {
        primary.setRound(2000e8, block.timestamp - HEARTBEAT);
        _assertQuote(2000e18, block.timestamp - HEARTBEAT, 7);
        primary.setRound(2000e8, block.timestamp - HEARTBEAT - 1);
        _assertQuote(1900e18, block.timestamp, 9);
    }

    function test_bothStaleUsesNewerPrimary() public {
        primary.setRound(2000e8, block.timestamp - 2 hours);
        secondary.setRound(1900e8, block.timestamp - 20 hours);
        _assertQuote(2000e18, block.timestamp - 2 hours, 7);
    }

    function test_bothStaleUsesNewerFallback() public {
        primary.setRound(2000e8, block.timestamp - 50 hours);
        secondary.setRound(1900e8, block.timestamp - 40 hours);
        _assertQuote(1900e18, block.timestamp - 40 hours, 9);
    }

    function test_equalStaleTimestampsPreferPrimary() public {
        primary.setRound(2000e8, block.timestamp - 2 hours);
        secondary.setRound(1900e8, block.timestamp - 2 hours);
        _assertQuote(2000e18, block.timestamp - 2 hours, 7);
    }

    function test_primaryRevertUsesFallback() public {
        primary.setFailRead(true);
        _assertQuote(1900e18, block.timestamp, 9);
    }

    function test_primaryRevertCanUseStaleFallback() public {
        primary.setFailRead(true);
        secondary.setRound(1900e8, block.timestamp - 90 days);
        _assertQuote(1900e18, block.timestamp - 90 days, 9);
    }

    function test_fallbackRevertRetainsStalePrimary() public {
        primary.setRound(2000e8, block.timestamp - 40 hours);
        secondary.setFailRead(true);
        _assertQuote(2000e18, block.timestamp - 40 hours, 7);
    }

    function test_primaryRecoveryRestoresPriority() public {
        primary.setFailRead(true);
        _assertQuote(1900e18, block.timestamp, 9);
        primary.setFailRead(false);
        primary.setRound(2100e8, block.timestamp);
        _assertQuote(2100e18, block.timestamp, 7);
    }

    function test_zeroNegativeZeroTimestampAndFuturePrimaryAreRejected() public {
        primary.setRound(0, block.timestamp);
        _assertQuote(1900e18, block.timestamp, 9);
        primary.setRound(-1, block.timestamp);
        _assertQuote(1900e18, block.timestamp, 9);
        primary.setRound(2000e8, 0);
        _assertQuote(1900e18, block.timestamp, 9);
        primary.setRound(2000e8, block.timestamp + 1);
        _assertQuote(1900e18, block.timestamp, 9);
    }

    function test_invalidFallbackDoesNotReplaceStalePrimary() public {
        primary.setRound(2000e8, block.timestamp - 2 hours);
        secondary.setRound(0, block.timestamp);
        _assertQuote(2000e18, block.timestamp - 2 hours, 7);
        secondary.setRound(-1, block.timestamp);
        _assertQuote(2000e18, block.timestamp - 2 hours, 7);
        secondary.setRound(1900e8, 0);
        _assertQuote(2000e18, block.timestamp - 2 hours, 7);
        secondary.setRound(1900e8, block.timestamp + 1);
        _assertQuote(2000e18, block.timestamp - 2 hours, 7);
    }

    function test_primaryBoundsAreStrict() public {
        primary.setBounds(2000e8, 3000e8);
        _assertQuote(1900e18, block.timestamp, 9);
        primary.setBounds(1, 2000e8);
        _assertQuote(1900e18, block.timestamp, 9);
    }

    function test_primaryBoundsFailuresDoNotDisableFallback() public {
        primary.setFailures(true, false, false);
        _assertQuote(1900e18, block.timestamp, 9);
        primary.setFailures(false, true, false);
        _assertQuote(1900e18, block.timestamp, 9);
        primary.setFailures(false, false, true);
        _assertQuote(1900e18, block.timestamp, 9);
    }

    function test_malformedRoundReturnDoesNotDisableFallback() public {
        vm.mockCall(address(primary), abi.encodeWithSignature("latestRoundData()"), hex"01");
        _assertQuote(1900e18, block.timestamp, 9);
    }

    function test_malformedFallbackRetainsStalePrimary() public {
        primary.setRound(2000e8, block.timestamp - 40 hours);
        vm.mockCall(address(secondary), abi.encodeWithSignature("latestRoundData()"), hex"01");
        _assertQuote(2000e18, block.timestamp - 40 hours, 7);
    }

    function test_malformedRoundIdDoesNotDisableFallback() public {
        vm.mockCall(
            address(primary),
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint256(type(uint80).max) + 1, int256(2000e8), block.timestamp, block.timestamp, uint256(7))
        );
        _assertQuote(1900e18, block.timestamp, 9);
    }

    function test_malformedAggregatorDoesNotDisableFallback() public {
        vm.mockCall(address(primary), abi.encodeWithSignature("aggregator()"), abi.encode(type(uint256).max));
        _assertQuote(1900e18, block.timestamp, 9);
    }

    function test_malformedBoundsDoNotDisableFallback() public {
        vm.mockCall(address(primary), abi.encodeWithSignature("minAnswer()"), hex"01");
        _assertQuote(1900e18, block.timestamp, 9);
    }

    function test_malformedSignedBoundDoesNotDisableFallback() public {
        vm.mockCall(address(primary), abi.encodeWithSignature("minAnswer()"), abi.encode(uint256(1) << 191));
        _assertQuote(1900e18, block.timestamp, 9);
    }

    function test_singleSourceRetainsAgeWithoutChangingLegacyBase() public {
        DualFeedPriceFeed single = new DualFeedPriceFeed(address(this), address(primary), address(0), HEARTBEAT);
        ChainlinkBasePriceFeed legacy =
            new ChainlinkBasePriceFeed(address(this), address(primary), address(0), HEARTBEAT);
        primary.setRound(2000e8, block.timestamp - 40 hours);
        (, int256 answer,, uint256 timestamp,) = single.latestRoundData();
        assertEq(answer, 2000e18);
        assertEq(timestamp, block.timestamp - 40 hours);
        assertFalse(single.hasFallback());
        (,,, uint256 legacyTimestamp,) = legacy.latestRoundData();
        assertEq(legacyTimestamp, 0);
        primary.setFailRead(true);
        vm.expectRevert(DualFeedPriceFeed.NoValidPrice.selector);
        single.latestRoundData();
    }

    function test_overflowingFallbackQuoteDoesNotDisablePrimary() public {
        primary.setRound(2000e8, block.timestamp - 2 hours);
        secondary.setRound(type(int256).max, block.timestamp);
        _assertQuote(2000e18, block.timestamp - 2 hours, 7);
    }

    function test_normalizesSourcesWithDifferentDecimals() public {
        DualFeedSourceMock other = new DualFeedSourceMock(20);
        other.setRound(1900e20, block.timestamp);
        DualFeedPriceFeed mixed = new DualFeedPriceFeed(address(this), address(primary), address(other), HEARTBEAT);
        primary.setFailRead(true);
        (, int256 answer,, uint256 timestamp,) = mixed.latestRoundData();
        assertEq(answer, 1900e18);
        assertEq(timestamp, block.timestamp);
    }

    function test_normalizesEighteenDecimalPrimaryWithoutRescaling() public {
        DualFeedSourceMock other = new DualFeedSourceMock(18);
        other.setRound(2000e18, block.timestamp);
        DualFeedPriceFeed mixed = new DualFeedPriceFeed(address(this), address(other), address(secondary), HEARTBEAT);
        assertEq(mixed.latestAnswer(), 2000e18);
    }

    function test_downscalingToZeroInvalidatesQuote() public {
        DualFeedSourceMock other = new DualFeedSourceMock(20);
        other.setRound(1, block.timestamp);
        DualFeedPriceFeed mixed = new DualFeedPriceFeed(address(this), address(primary), address(other), HEARTBEAT);
        primary.setRound(2000e8, block.timestamp - 2 hours);
        assertEq(mixed.latestAnswer(), 2000e18);
    }

    function test_bothUnreadableRevertWithoutInventingPrice() public {
        primary.setFailRead(true);
        secondary.setFailRead(true);
        vm.expectRevert(DualFeedPriceFeed.NoValidPrice.selector);
        feed.latestRoundData();
    }

    function test_bothInvalidRevertWithoutInventingPrice() public {
        primary.setRound(0, block.timestamp);
        secondary.setRound(0, block.timestamp);
        vm.expectRevert(DualFeedPriceFeed.NoValidPrice.selector);
        feed.latestRoundData();
    }

    function test_ownerControlsHeartbeatAndOwnership() public {
        vm.prank(address(1));
        vm.expectRevert("Only owner");
        feed.setHeartbeat(100);
        vm.expectRevert("Invalid heartbeat");
        feed.setHeartbeat(0);
        feed.setHeartbeat(100);
        assertEq(feed.assetToUsdHeartbeat(), 100);
        feed.setPendingOwner(address(1));
        vm.expectRevert("Only pending owner");
        feed.acceptOwner();
        vm.prank(address(1));
        feed.acceptOwner();
        assertEq(feed.owner(), address(1));
        assertEq(feed.pendingOwner(), address(0));
    }

    function test_constructorRejectsUnsupportedDecimals() public {
        DualFeedSourceMock other = new DualFeedSourceMock(37);
        vm.expectRevert("Unsupported decimals");
        new DualFeedPriceFeed(address(this), address(primary), address(other), HEARTBEAT);
    }

    function testFuzz_bothStalePreserveNewestQuoteAndTimestamp(uint256 ageA, uint256 ageB) public {
        ageA = bound(ageA, HEARTBEAT + 1, 365 days);
        ageB = bound(ageB, HEARTBEAT + 1, 365 days);
        primary.setRound(2000e8, block.timestamp - ageA);
        secondary.setRound(1900e8, block.timestamp - ageB);
        if (ageA <= ageB) _assertQuote(2000e18, block.timestamp - ageA, 7);
        else _assertQuote(1900e18, block.timestamp - ageB, 9);
    }

    function _assertQuote(int256 expected, uint256 timestamp, uint80 id) internal view {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            feed.latestRoundData();
        assertEq(answer, expected);
        assertEq(updatedAt, timestamp);
        assertEq(startedAt, timestamp);
        assertEq(roundId, id);
        assertEq(answeredInRound, id);
        assertEq(feed.latestAnswer(), answer);
        assertEq(feed.decimals(), 18);
    }
}
