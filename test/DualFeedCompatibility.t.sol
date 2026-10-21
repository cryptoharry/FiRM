// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IChainlinkFeed} from "src/interfaces/IChainlinkFeed.sol";
import {ChainlinkBasePriceFeed} from "src/feeds/ChainlinkBasePriceFeed.sol";
import {DualFeedPriceFeed} from "src/feeds/DualFeedPriceFeed.sol";
import {DualFeedSourceMock} from "test/mocks/DualFeedMocks.sol";

contract DualFeedCompatibilityTest is Test {
    uint256 constant HEARTBEAT = 3660;
    DualFeedSourceMock primary;
    DualFeedSourceMock secondary;
    ChainlinkBasePriceFeed legacy;
    DualFeedPriceFeed dual;

    function setUp() public {
        vm.warp(1000 days);
        _configure(8, 8);
    }

    function test_freshPrimaryPreservesDistinctMetadata() public {
        _assertMetadata(false, false);
    }

    function test_freshFallbackPreservesDistinctMetadata() public {
        _assertMetadata(true, false);
    }

    function test_newerStalePrimaryPreservesDistinctMetadata() public {
        _assertMetadata(false, true);
    }

    function test_newerStaleFallbackPreservesDistinctMetadata() public {
        _assertMetadata(true, true);
    }

    function testFuzz_matchesBaseForFreshPrimary(
        uint8 primaryDecimals,
        uint8 fallbackDecimals,
        uint256 rawPrice,
        uint256 age
    ) public {
        primaryDecimals = uint8(bound(primaryDecimals, 0, 36));
        fallbackDecimals = uint8(bound(fallbackDecimals, 0, 36));
        _configure(primaryDecimals, fallbackDecimals);
        primary.setRound(_validPrice(rawPrice, primaryDecimals), block.timestamp - bound(age, 0, HEARTBEAT));
        _assertMatchesBase(7);
    }

    function testFuzz_matchesBaseForFreshFallback(
        uint8 primaryDecimals,
        uint8 fallbackDecimals,
        uint256 rawPrice,
        uint256 age
    ) public {
        primaryDecimals = uint8(bound(primaryDecimals, 0, 36));
        fallbackDecimals = uint8(bound(fallbackDecimals, 0, 36));
        _configure(primaryDecimals, fallbackDecimals);
        primary.setRound(primary.answer(), block.timestamp - HEARTBEAT - 1);
        secondary.setRound(_validPrice(rawPrice, fallbackDecimals), block.timestamp - bound(age, 0, HEARTBEAT));
        _assertMatchesBase(9);
    }

    function testFuzz_matchesBaseAroundPrimaryBounds(
        uint8 primaryDecimals,
        uint8 fallbackDecimals,
        uint256 rawPrice,
        bool upperBound
    ) public {
        primaryDecimals = uint8(bound(primaryDecimals, 0, 36));
        fallbackDecimals = uint8(bound(fallbackDecimals, 0, 36));
        _configure(primaryDecimals, fallbackDecimals);
        int256 boundary = _validPrice(rawPrice, primaryDecimals);
        if (upperBound) primary.setBounds(1, int192(boundary));
        else primary.setBounds(int192(boundary), type(int192).max);

        for (int256 delta = -1; delta <= 1; ++delta) {
            primary.setRound(boundary + delta, block.timestamp);
            bool withinBounds = upperBound ? delta < 0 : delta > 0;
            _assertMatchesBase(withinBounds ? 7 : 9);
        }
    }

    function _configure(uint8 primaryDecimals, uint8 fallbackDecimals) internal {
        primary = new DualFeedSourceMock(primaryDecimals);
        secondary = new DualFeedSourceMock(fallbackDecimals);
        primary.setRound(int256(2 * 10 ** primaryDecimals), block.timestamp);
        secondary.setRound(int256(3 * 10 ** fallbackDecimals), block.timestamp);
        secondary.setRoundId(9);
        legacy = new ChainlinkBasePriceFeed(address(this), address(primary), address(secondary), HEARTBEAT);
        dual = new DualFeedPriceFeed(address(this), address(primary), address(secondary), HEARTBEAT);
    }

    function _validPrice(uint256 seed, uint8 sourceDecimals) internal returns (int256) {
        // Keep quotes positive, nonzero after normalization, and within int192 bounds.
        uint256 unit = 10 ** sourceDecimals;
        return int256(bound(seed, 3 * unit, 1_000_000 * unit));
    }

    function _assertMatchesBase(uint80 expectedRound) internal view {
        assertEq(_roundData(IChainlinkFeed(address(dual))), _roundData(IChainlinkFeed(address(legacy))));
        (uint80 roundId,,,,) = dual.latestRoundData();
        assertEq(roundId, expectedRound);
        assertEq(dual.latestAnswer(), legacy.latestAnswer());
    }

    function _roundData(IChainlinkFeed source) internal view returns (bytes memory) {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            source.latestRoundData();
        return abi.encode(roundId, answer, startedAt, updatedAt, answeredInRound);
    }

    function _assertMetadata(bool useFallback, bool bothStale) internal {
        uint256 primaryAt = block.timestamp - (bothStale ? 2 hours : 2 minutes);
        uint256 fallbackAt = block.timestamp - (bothStale ? 3 hours : 1 minutes);
        if (useFallback) primaryAt = block.timestamp - (bothStale ? 4 hours : 2 hours);
        uint256 primaryStart = block.timestamp - 12 hours;
        uint256 fallbackStart = block.timestamp - 24 hours;
        vm.mockCall(
            address(primary),
            abi.encodeWithSelector(IChainlinkFeed.latestRoundData.selector),
            abi.encode(uint80(17), int256(2000e8), primaryStart, primaryAt, uint80(19))
        );
        vm.mockCall(
            address(secondary),
            abi.encodeWithSelector(IChainlinkFeed.latestRoundData.selector),
            abi.encode(uint80(31), int256(1900e8), fallbackStart, fallbackAt, uint80(37))
        );

        bytes memory expected = useFallback
            ? abi.encode(uint80(31), int256(1900e18), fallbackStart, fallbackAt, uint80(37))
            : abi.encode(uint80(17), int256(2000e18), primaryStart, primaryAt, uint80(19));
        assertEq(_roundData(IChainlinkFeed(address(dual))), expected);
        assertEq(dual.latestAnswer(), useFallback ? int256(1900e18) : int256(2000e18));
    }
}
