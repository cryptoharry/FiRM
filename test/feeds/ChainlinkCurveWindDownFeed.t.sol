// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ChainlinkCurveWindDownFeed} from "src/feeds/ChainlinkCurveWindDownFeed.sol";
import {ChainlinkCurveFeed} from "src/feeds/ChainlinkCurveFeed.sol";
import {CurveLPPessimisticFeed} from "src/feeds/CurveLPPessimisticFeed.sol";
import {CurveLPYearnV2Feed} from "src/feeds/CurveLPYearnV2Feed.sol";
import {BorrowController} from "src/BorrowController.sol";
import {Oracle, IChainlinkFeed as OracleFeed} from "src/Oracle.sol";

contract WindDownMockBase {
    uint8 public decimals = 18;
    int256 public price = 1e18;
    uint256 public updatedAt = block.timestamp;
    bool public fail;

    function set(int256 p, uint256 t, bool f) external {
        price = p;
        updatedAt = t;
        fail = f;
    }

    function setDecimals(uint8 d) external {
        decimals = d;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!fail, "base failure");
        return (42, price, updatedAt, updatedAt, 42);
    }
}

contract WindDownMockToken {
    string public symbol;

    constructor(string memory s) {
        symbol = s;
    }
}

contract WindDownMockPool {
    address[3] public coins;
    uint256[2] public prices;
    bool public fail;

    constructor(address token) {
        coins = [token, address(1), address(2)];
        prices = [uint256(1e18), uint256(1e18)];
    }

    function set(uint256 k, uint256 p, bool f) external {
        prices[k] = p;
        fail = f;
    }

    function price_oracle(uint256 k) external view returns (uint256) {
        require(!fail, "pool failure");
        return prices[k];
    }

    function get_virtual_price() external pure returns (uint256) {
        return 1.1e18;
    }

    function symbol() external pure returns (string memory) {
        return "TEST-LP";
    }
}

contract WindDownMockYearn {
    function symbol() external pure returns (string memory) {
        return "yvTEST-LP";
    }

    function totalSupply() external pure returns (uint256) {
        return 1e18;
    }

    function totalAssets() external pure returns (uint256) {
        return 1.2e18;
    }

    function lastReport() external view returns (uint256) {
        return block.timestamp;
    }

    function lockedProfitDegradation() external pure returns (uint256) {
        return 0;
    }

    function lockedProfit() external pure returns (uint256) {
        return 0;
    }
}

contract WindDownMockMarket {
    address public oracle;
    address public collateral;

    constructor(address o, address c) {
        oracle = o;
        collateral = c;
    }
}

contract WindDownMockDBR {
    function lastUpdated(address) external pure returns (uint256) {
        return 0;
    }

    function debts(address) external pure returns (uint256) {
        return 0;
    }
}

contract WindDownMockDola {
    mapping(address => uint256) public balanceOf;
    uint256 public transferCalls;
    bool public observedWindDownStarted;
    bool public fail;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function setFail(bool f) external {
        fail = f;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(!fail, "DOLA failure");
        observedWindDownStarted = (ChainlinkCurveWindDownFeed(msg.sender).windDownStartPrice() != 0);
        transferCalls++;
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract ChainlinkCurveWindDownFeedTest is Test {
    WindDownMockBase base;
    WindDownMockPool pool;
    ChainlinkCurveWindDownFeed feed;
    WindDownMockDola dola;
    uint32 constant DURATION = 1 days;
    uint256 constant BORROW_STALENESS_THRESHOLD = 1 days + 1 minutes;

    function setUp() public {
        vm.warp(10 days);
        base = new WindDownMockBase();
        pool = new WindDownMockPool(address(new WindDownMockToken("TOKEN")));
        feed = deploy(0, DURATION);
        WindDownMockDola mockDola = new WindDownMockDola();
        vm.etch(address(feed.dola()), address(mockDola).code);
        dola = WindDownMockDola(address(feed.dola()));
    }

    function deploy(uint256 k, uint32 duration) internal returns (ChainlinkCurveWindDownFeed) {
        return new ChainlinkCurveWindDownFeed(address(base), address(pool), k, duration);
    }

    function activate() internal {
        pool.set(0, 1.9e18, false);
        feed.startWindDown();
    }

    function testRewardPaidImmediatelyToActivationCaller() public {
        address caller = address(123);
        dola.mint(address(feed), 10e18);
        pool.set(0, 1.9e18, false);
        assertTrue(feed.canStartWindDown());
        assertEq(dola.balanceOf(caller), 0); // readiness reads do not pay
        uint256 price = uint256(feed.latestAnswer());
        vm.recordLogs();
        vm.prank(caller);
        feed.startWindDown();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(feed));
        assertEq(logs[0].topics[0], keccak256("WindDownStarted(address,uint256,uint256,uint256,uint256,uint256)"));
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(caller))));
        assertEq(logs[0].data, abi.encode(block.timestamp, price, uint256(1.9e18), DURATION, uint256(10e18)));
        assertEq(dola.balanceOf(caller), 10e18);
        assertEq(dola.balanceOf(address(feed)), 0);
        assertTrue(dola.observedWindDownStarted()); // state finalized before the transfer
        assertEq(feed.windDownStartedAt(), block.timestamp);
        assertEq(feed.latestAnswer(), int256(price)); // no time needs to elapse for payout
    }

    function testZeroBalanceStillTransfersAndActivates() public {
        assertEq(dola.balanceOf(address(feed)), 0);
        activate();
        assertGt(feed.windDownStartPrice(), 0);
        assertEq(dola.transferCalls(), 1);
        assertEq(dola.balanceOf(address(this)), 0);
    }

    function testCannotClaimAgainEvenIfFundedAfterActivation() public {
        dola.mint(address(feed), 10e18);
        activate();
        dola.mint(address(feed), 5e18);
        vm.expectRevert(ChainlinkCurveWindDownFeed.WindDownAlreadyStarted.selector);
        feed.startWindDown();
        assertEq(dola.balanceOf(address(this)), 10e18);
        assertEq(dola.balanceOf(address(feed)), 5e18);
        assertEq(dola.transferCalls(), 1);
    }

    function testIneligibleCallerCannotCollectReward() public {
        dola.mint(address(feed), 10e18);
        vm.expectRevert(ChainlinkCurveWindDownFeed.TriggerNotReached.selector);
        feed.startWindDown();
        assertEq(dola.balanceOf(address(feed)), 10e18);
        assertEq(dola.transferCalls(), 0);
        assertEq(feed.windDownStartPrice(), 0);
    }

    function testRevertingTransferRollsBackActivation() public {
        dola.mint(address(feed), 10e18);
        dola.setFail(true);
        pool.set(0, 1.9e18, false);
        vm.expectRevert(bytes("DOLA failure"));
        feed.startWindDown();
        assertEq(feed.windDownStartPrice(), 0);
        assertEq(feed.windDownStartedAt(), 0);
        assertEq(dola.balanceOf(address(feed)), 10e18);
    }

    function testGenericMetadataAndFixedThreshold() public view {
        assertEq(feed.description(), "TOKEN / USD");
        assertEq(feed.targetIndex(), 0);
        assertEq(feed.decimals(), 18);
        assertEq(feed.WIND_DOWN_TRIGGER_EMA(), 1.9e18);
    }

    function testFuzzNormalModeMatchesExistingFeed(uint256 basePrice, uint64 ema) public {
        basePrice = bound(basePrice, 1e18, uint256(type(int256).max) / 1e18);
        ema = uint64(bound(ema, 1, 2e18));
        base.set(int256(basePrice), block.timestamp, false);
        pool.set(0, ema, false);
        ChainlinkCurveFeed existing = new ChainlinkCurveFeed(address(base), address(pool), 0, 0);
        (bool ok, bytes memory actual) = address(feed).staticcall(abi.encodeWithSignature("latestRoundData()"));
        (bool oldOk, bytes memory expected) = address(existing).staticcall(abi.encodeWithSignature("latestRoundData()"));
        assertTrue(ok && oldOk);
        assertEq(actual, expected);
        assertEq(feed.latestAnswer(), existing.latestAnswer());
    }

    function testNonzeroOracleIndexAndDifferentAsset() public {
        pool = new WindDownMockPool(address(new WindDownMockToken("OTHER")));
        ChainlinkCurveWindDownFeed other = deploy(1, DURATION);
        pool.set(0, 2e18, false);
        pool.set(1, 1.5e18, false);
        assertEq(other.description(), "OTHER / USD");
        assertEq(other.assetOrTargetK(), 1);
        assertEq(other.latestAnswer(), int256(uint256(1e36) / 1.5e18));
        assertFalse(other.canStartWindDown());
        pool.set(1, 1.9e18, false);
        assertTrue(other.canStartWindDown());
        other.startWindDown();
        assertGt(other.windDownStartPrice(), 0);
    }

    function testThresholdBoundaryAndPermissionlessActivation() public {
        pool.set(0, 1.9e18 - 1, false);
        assertFalse(feed.canStartWindDown());
        vm.expectRevert(ChainlinkCurveWindDownFeed.TriggerNotReached.selector);
        feed.startWindDown();
        pool.set(0, 1.9e18, false);
        assertTrue(feed.canStartWindDown());
        uint256 preview = uint256(feed.latestAnswer());
        assertEq(feed.windDownStartPrice(), 0); // reading cannot activate
        vm.prank(address(123));
        feed.startWindDown();
        assertEq(feed.windDownStartPrice(), preview);
        assertEq(feed.windDownStartedAt(), block.timestamp);
    }

    function testCanStartRechecksAtExecution() public {
        pool.set(0, 1.9e18, false);
        assertTrue(feed.canStartWindDown());
        pool.set(0, 1.8e18, false);
        vm.expectRevert(ChainlinkCurveWindDownFeed.TriggerNotReached.selector);
        feed.startWindDown();
        assertEq(feed.windDownStartPrice(), 0);
    }

    function testActivationIgnoresBaseFeedTimestamp() public {
        pool.set(0, 1.9e18, false);
        uint256[3] memory timestamps = [uint256(0), uint256(1), block.timestamp + 1];
        for (uint256 i; i < timestamps.length; i++) {
            feed = deploy(0, DURATION);
            base.set(1e18, timestamps[i], false);
            assertTrue(feed.canStartWindDown());
            uint256 price = uint256(feed.latestAnswer());
            feed.startWindDown();
            assertGt(feed.windDownStartPrice(), 0);
            assertEq(feed.windDownStartPrice(), price);
            (,, uint256 startedAt, uint256 updatedAt,) = feed.latestRoundData();
            assertEq(startedAt, 0);
            assertEq(updatedAt, 0);
        }
    }

    function testEligibilityDoesNotReadBaseFeedAndPoolFailuresRevert() public {
        pool.set(0, 1.9e18, false);
        base.set(1e18, block.timestamp, true);
        assertTrue(feed.canStartWindDown());
        vm.expectRevert(bytes("base failure"));
        feed.startWindDown();
        assertEq(feed.windDownStartPrice(), 0);
        base.set(1e18, block.timestamp, false);
        pool.set(0, 0, false);
        assertFalse(feed.canStartWindDown());
        pool.set(0, 1.9e18, true);
        vm.expectRevert(bytes("pool failure"));
        feed.canStartWindDown();
        vm.expectRevert(bytes("pool failure"));
        feed.startWindDown();
        assertEq(feed.windDownStartPrice(), 0);
    }

    function testActivationHasNoAdditionalEmaCeiling() public {
        pool.set(0, 3e18, false);
        assertTrue(feed.canStartWindDown());
        assertEq(feed.latestAnswer(), int256(uint256(1e36) / 3e18));
        feed.startWindDown();
        assertEq(feed.windDownStartPrice(), uint256(1e36) / 3e18);
        assertFalse(feed.canStartWindDown());
    }

    function testMinimumStartingPriceLatchesAtTimestampZero() public {
        vm.warp(0);
        base.set(2, 0, false);
        activate();
        assertEq(feed.windDownStartedAt(), 0);
        assertEq(feed.windDownStartPrice(), 1);
        assertFalse(feed.canStartWindDown());
        vm.expectRevert(ChainlinkCurveWindDownFeed.WindDownAlreadyStarted.selector);
        feed.startWindDown();
        vm.warp(DURATION);
        assertEq(feed.latestAnswer(), 1);
    }

    function testInvalidConstructor() public {
        vm.expectRevert(ChainlinkCurveWindDownFeed.InvalidConfiguration.selector);
        deploy(0, 0);
        base.setDecimals(8);
        vm.expectRevert(ChainlinkCurveWindDownFeed.InvalidConfiguration.selector);
        deploy(0, DURATION);
        base.setDecimals(18);
        vm.expectRevert();
        deploy(2, DURATION);
        vm.expectRevert();
        new ChainlinkCurveWindDownFeed(address(0), address(pool), 0, DURATION);
        vm.expectRevert();
        new ChainlinkCurveWindDownFeed(address(base), address(0), 0, DURATION);
    }

    function testInvalidLivePricesRevertAndCannotActivate() public {
        pool.set(0, 1.9e18, false);
        int256[5] memory invalidPrices =
            [int256(-1), type(int256).min, int256(0), int256(1), type(int256).max / 1e18 + 1];
        for (uint256 i; i < invalidPrices.length; i++) {
            base.set(invalidPrices[i], block.timestamp, false);
            assertTrue(feed.canStartWindDown()); // trigger eligibility does not validate the USD price
            vm.expectRevert();
            feed.latestRoundData();
            vm.expectRevert();
            feed.startWindDown();
            assertEq(feed.windDownStartPrice(), 0);
        }
        base.set(1e18, block.timestamp, false);
        pool.set(0, 0, false);
        vm.expectRevert(); // division by zero is checked by Solidity
        feed.latestRoundData();
    }

    function testPermanentActivationAndOutages() public {
        activate();
        assertFalse(feed.canStartWindDown());
        vm.expectRevert(ChainlinkCurveWindDownFeed.WindDownAlreadyStarted.selector);
        feed.startWindDown();
        uint256 startingPrice = feed.windDownStartPrice();
        pool.set(0, 1e18, false);
        assertEq(feed.latestAnswer(), int256(startingPrice));
        base.set(0, 0, true);
        pool.set(0, 0, true);
        assertFalse(feed.canStartWindDown()); // the permanent latch skips the failed pool call
        vm.warp(block.timestamp + DURATION / 2);
        assertEq(feed.latestAnswer(), int256(1 + (startingPrice - 1) / 2));
        (uint80 roundId,, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) = feed.latestRoundData();
        assertEq(roundId, 0);
        assertEq(answeredInRound, 0);
        assertEq(startedAt, 0);
        assertEq(updatedAt, 0);
    }

    function testFuzzDecay(uint32 elapsed, uint96 price, uint32 duration) public {
        price = uint96(bound(price, 2, type(uint96).max));
        duration = uint32(bound(duration, 1, type(uint32).max));
        feed = deploy(0, duration);
        base.set(int256(uint256(price)), block.timestamp, false);
        activate();
        uint256 start = feed.windDownStartPrice();
        assertEq(feed.latestAnswer(), int256(start));
        vm.warp(block.timestamp + elapsed);
        uint256 expected = elapsed >= duration ? 1 : 1 + (start - 1) * (duration - elapsed) / duration;
        assertEq(feed.latestAnswer(), int256(expected));
        assertLe(uint256(feed.latestAnswer()), start);
        assertGe(feed.latestAnswer(), 1);
        (,, uint256 startedAt, uint256 updatedAt,) = feed.latestRoundData();
        assertEq(startedAt, 0);
        assertEq(updatedAt, 0);
    }

    function testEndpointAndMaximumArithmetic() public {
        feed = deploy(0, type(uint32).max);
        base.set(type(int256).max / 1e18, block.timestamp, false);
        activate();
        uint256 startTime = block.timestamp;
        uint256 startPrice = feed.windDownStartPrice();
        assertEq(feed.latestAnswer(), int256(startPrice));
        vm.warp(startTime + type(uint32).max - 1);
        assertEq(feed.latestAnswer(), int256(1 + (startPrice - 1) / type(uint32).max));
        vm.warp(startTime + type(uint32).max);
        assertEq(feed.latestAnswer(), 1);
        vm.warp(block.timestamp + 365 days);
        assertEq(feed.latestAnswer(), 1);
    }

    function testLPAndYearnPropagationBlocksBorrowingButKeepsPriceReadable() public {
        WindDownMockBase otherCoin = new WindDownMockBase();
        CurveLPPessimisticFeed lp = new CurveLPPessimisticFeed(address(pool), address(feed), address(otherCoin), false);
        CurveLPYearnV2Feed yv = new CurveLPYearnV2Feed(address(new WindDownMockYearn()), address(lp));
        Oracle oracle = new Oracle(address(this));
        address collateral = address(0xCA11);
        oracle.setFeed(collateral, OracleFeed(address(yv)), 18);
        WindDownMockMarket market = new WindDownMockMarket(address(oracle), collateral);
        BorrowController controller = new BorrowController(address(this), address(new WindDownMockDBR()));
        controller.setStalenessThreshold(address(market), BORROW_STALENESS_THRESHOLD);
        controller.allow(address(this));
        assertFalse(controller.isPriceStale(address(market)));
        vm.prank(address(market));
        assertTrue(controller.borrowAllowed(address(this), address(456), 1e18));
        activate();
        // Timestamp minimum is independent of which coin supplies the minimum price.
        otherCoin.set(0.1e18, block.timestamp, false);
        (,,, uint256 lpTimestamp,) = lp.latestRoundData();
        (, int256 yvPrice,, uint256 yvTimestamp,) = yv.latestRoundData();
        assertEq(lpTimestamp, 0);
        assertEq(yvTimestamp, 0);
        assertGt(yvPrice, 0);
        assertTrue(controller.isPriceStale(address(market)));
        vm.prank(address(market));
        assertFalse(controller.borrowAllowed(address(this), address(456), 1e18));
        assertGt(oracle.viewPrice(collateral, 8500), 0); // liquidation pricing remains available
        controller.setStalenessThreshold(address(market), 0);
        assertFalse(controller.isPriceStale(address(market))); // deployment prerequisite
    }
}

