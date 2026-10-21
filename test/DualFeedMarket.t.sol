// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "test/FiRMBaseTest.sol";
import {DualFeedPriceFeed} from "src/feeds/DualFeedPriceFeed.sol";
import {RedstoneStoredPriceFeed} from "src/feeds/RedstoneStoredPriceFeed.sol";
import {ChainlinkBasePriceFeed} from "src/feeds/ChainlinkBasePriceFeed.sol";
import {DualFeedSourceMock, RedstoneAdapterMock, ExpiringRedstoneFeedMock} from "test/mocks/DualFeedMocks.sol";

contract DualFeedMarketTest is FiRMBaseTest {
    DualFeedSourceMock primary;
    RedstoneAdapterMock adapter;
    DualFeedPriceFeed dual;
    ChainlinkBasePriceFeed legacy;
    uint256 fallbackTimestamp;

    function setUp() public {
        initialize(
            replenishmentPriceBps,
            collateralFactorBps,
            replenishmentIncentiveBps,
            liquidationBonusBps,
            callOnDepositCallback
        );
        primary = new DualFeedSourceMock(8);
        adapter = new RedstoneAdapterMock();
        RedstoneStoredPriceFeed stored = new RedstoneStoredPriceFeed(address(adapter), bytes32("ETH"), "ETH / USD");
        dual = new DualFeedPriceFeed(gov, address(primary), address(stored), 3660);
        ExpiringRedstoneFeedMock expiring = new ExpiringRedstoneFeedMock(adapter);
        legacy = new ChainlinkBasePriceFeed(gov, address(primary), address(expiring), 3660);
        vm.startPrank(gov);
        oracle.setFeed(address(WETH), IChainlinkFeed(address(dual)), 18);
        borrowController.setStalenessThreshold(address(market), 3660);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days);
        primary.setRound(2000e8, block.timestamp);
        adapter.set(block.timestamp * 1000, block.timestamp, 2000e8);
        gibDOLA(address(market), 10000 ether);
        gibWeth(user, 1 ether);
        gibDBR(user, 10000 ether);
        vm.startPrank(user, user);
        WETH.approve(address(market), 1 ether);
        market.deposit(user, 1 ether);
        market.borrow(1000 ether);
        vm.stopPrank();
    }

    function test_staleBorrowingIsDeniedWhileLiquidationSettlesAtRedstoneExpiry() public {
        _outage();
        assertTrue(borrowController.isPriceStale(address(market)));
        vm.prank(user, user);
        vm.expectRevert("Denied by borrow controller");
        market.borrow(1 ether);

        uint256 repaid = 250 ether;
        gibDOLA(user2, repaid);
        vm.prank(user2);
        DOLA.approve(address(market), repaid);

        // Same debt, escrow, oracle cache and providers: the old component fails.
        vm.prank(gov);
        oracle.setFeed(address(WETH), IChainlinkFeed(address(legacy)), 18);
        vm.prank(user2);
        vm.expectRevert("Redstone expired");
        market.liquidate(user, repaid);

        vm.prank(gov);
        oracle.setFeed(address(WETH), IChainlinkFeed(address(dual)), 18);
        uint256 escrowBefore = WETH.balanceOf(address(market.escrows(user)));
        uint256 marketDolaBefore = DOLA.balanceOf(address(market));
        vm.prank(user2);
        market.liquidate(user, repaid);

        uint256 expectedCollateral = repaid * 1 ether / 900e18;
        expectedCollateral += expectedCollateral * liquidationBonusBps / 10000;
        assertEq(market.debts(user), 750 ether);
        assertEq(WETH.balanceOf(user2), expectedCollateral);
        assertEq(WETH.balanceOf(address(market.escrows(user))), escrowBefore - expectedCollateral);
        assertEq(DOLA.balanceOf(address(market)), marketDolaBefore + repaid);
        (,,, uint256 timestamp,) = dual.latestRoundData();
        assertEq(timestamp, fallbackTimestamp);
    }

    function test_recoveryRestoresFreshnessWithoutErasingPessimisticLow() public {
        _outage();
        assertEq(oracle.getPrice(address(WETH), collateralFactorBps), 900e18);
        uint256 day = block.timestamp / 1 days;
        primary.setRound(2000e8, block.timestamp);
        assertFalse(borrowController.isPriceStale(address(market)));
        assertEq(dual.latestAnswer(), 2000e18);
        assertEq(oracle.dailyLows(address(WETH), day), 900e18);
        assertEq(oracle.viewPrice(address(WETH), collateralFactorBps), 900e18 * 10000 / collateralFactorBps);

        vm.warp(block.timestamp + 2 days);
        primary.setRound(2000e8, block.timestamp);
        assertEq(oracle.viewPrice(address(WETH), collateralFactorBps), 2000e18);
    }

    function test_freshFallbackAllowsBorrowingDuringPrimaryReadFailure() public {
        primary.setFailRead(true);
        assertFalse(borrowController.isPriceStale(address(market)));
        vm.prank(user, user);
        market.borrow(100 ether);
        assertEq(market.debts(user), 1100 ether);
    }

    function _outage() internal {
        vm.warp(block.timestamp + 1 minutes);
        primary.setRound(1000e8, block.timestamp);
        vm.warp(block.timestamp + 4 minutes);
        fallbackTimestamp = block.timestamp;
        adapter.set(block.timestamp * 1000, block.timestamp, 900e8);
        vm.warp(block.timestamp + 30 hours);
    }
}
