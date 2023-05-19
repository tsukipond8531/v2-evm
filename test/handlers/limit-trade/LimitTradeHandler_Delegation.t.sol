// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import { LimitTradeHandler_Base, IPerpStorage, IConfigStorage } from "./LimitTradeHandler_Base.t.sol";
import { ILimitTradeHandler } from "@hmx/handlers/interfaces/ILimitTradeHandler.sol";
import { LimitOrderTester } from "../../testers/LimitOrderTester.sol";
import { MockAccountAbstraction } from "../../mocks/MockAccountAbstraction.sol";

// What is this test DONE
// - revert
//   - Try creating an order will too low execution fee
//   - Try creating an order with incorrect `msg.value`
//   - Try creating an order with sub-account id > 255
// - success
//   - Try creating BUY and SELL orders and check that the indices of the orders are correct and that all orders are created correctly.

struct Price {
  // Price
  int64 price;
  // Confidence interval around the price
  uint64 conf;
  // Price exponent
  int32 expo;
  // Unix timestamp describing when the price was published
  uint publishTime;
}

// PriceFeed represents a current aggregate price from pyth publisher feeds.
struct PriceFeed {
  // The price ID.
  bytes32 id;
  // Latest available price
  Price price;
  // Latest available exponentially-weighted moving average price
  Price emaPrice;
}

contract LimitTradeHandler_Delegation is LimitTradeHandler_Base {
  bytes[] internal priceData;
  bytes32[] internal priceUpdateData;
  bytes32[] internal publishTimeUpdateData;

  function setUp() public override {
    super.setUp();

    priceData = new bytes[](1);
    priceData[0] = abi.encode(
      PriceFeed({
        id: "1234",
        price: Price({ price: 0, conf: 0, expo: 0, publishTime: block.timestamp }),
        emaPrice: Price({ price: 0, conf: 0, expo: 0, publishTime: block.timestamp })
      })
    );

    limitTradeHandler.setOrderExecutor(address(this), true);

    configStorage.addMarketConfig(
      IConfigStorage.MarketConfig({
        assetId: "A",
        maxLongPositionSize: 10_000_000 * 1e30,
        maxShortPositionSize: 10_000_000 * 1e30,
        assetClass: 1,
        maxProfitRateBPS: 9 * 1e4,
        minLeverageBPS: 1 * 1e4,
        initialMarginFractionBPS: 0.01 * 1e4,
        maintenanceMarginFractionBPS: 0.005 * 1e4,
        increasePositionFeeRateBPS: 0,
        decreasePositionFeeRateBPS: 0,
        allowIncreasePosition: true,
        active: true,
        fundingRate: IConfigStorage.FundingRate({ maxFundingRate: 0, maxSkewScaleUSD: 0 })
      })
    );

    configStorage.addMarketConfig(
      IConfigStorage.MarketConfig({
        assetId: "A",
        maxLongPositionSize: 10_000_000 * 1e30,
        maxShortPositionSize: 10_000_000 * 1e30,
        assetClass: 1,
        maxProfitRateBPS: 9 * 1e4,
        minLeverageBPS: 1 * 1e4,
        initialMarginFractionBPS: 0.01 * 1e4,
        maintenanceMarginFractionBPS: 0.005 * 1e4,
        increasePositionFeeRateBPS: 0,
        decreasePositionFeeRateBPS: 0,
        allowIncreasePosition: true,
        active: true,
        fundingRate: IConfigStorage.FundingRate({ maxFundingRate: 0, maxSkewScaleUSD: 0 })
      })
    );

    configStorage.addMarketConfig(
      IConfigStorage.MarketConfig({
        assetId: "A",
        maxLongPositionSize: 10_000_000 * 1e30,
        maxShortPositionSize: 10_000_000 * 1e30,
        assetClass: 1,
        maxProfitRateBPS: 9 * 1e4,
        minLeverageBPS: 1 * 1e4,
        initialMarginFractionBPS: 0.01 * 1e4,
        maintenanceMarginFractionBPS: 0.005 * 1e4,
        increasePositionFeeRateBPS: 0,
        decreasePositionFeeRateBPS: 0,
        allowIncreasePosition: true,
        active: true,
        fundingRate: IConfigStorage.FundingRate({ maxFundingRate: 0, maxSkewScaleUSD: 0 })
      })
    );
  }

  function testCorrectness_createOrderViaEntryPoint() external {
    vm.startPrank(ALICE);
    MockAccountAbstraction aliceAA = new MockAccountAbstraction(address(entryPoint));
    limitTradeHandler.setDelegate(address(aliceAA));
    vm.stopPrank();

    // Create Buy Order
    mockOracle.setPrice(999 * 1e30);
    entryPoint.createOrder{ value: 0.1 ether }({
      account: address(aliceAA),
      target: address(limitTradeHandler),
      _subAccountId: 0,
      _marketIndex: 1,
      _sizeDelta: 1000 * 1e30,
      _triggerPrice: 1000 * 1e30,
      _acceptablePrice: 1025 * 1e30, // 1000 * (1 + 0.025) = 1025
      _triggerAboveThreshold: true,
      _executionFee: 0.1 ether,
      _reduceOnly: false,
      _tpToken: address(weth)
    });

    // Retrieve Buy Order that was just created.
    ILimitTradeHandler.LimitOrder memory limitOrder;
    (limitOrder.account, , , , , , , , , , , ) = limitTradeHandler.limitOrders(address(this), 0);
    assertEq(limitOrder.account, address(this), "Order should be created.");

    // Mock price to make the order executable
    mockOracle.setPrice(1001 * 1e30);
    mockOracle.setMarketStatus(2);
    mockOracle.setPriceStale(false);

    // Execute Long Increase Order
    limitTradeHandler.executeOrder({
      _account: address(this),
      _subAccountId: 0,
      _orderIndex: 0,
      _feeReceiver: payable(ALICE),
      _priceData: priceUpdateData,
      _publishTimeData: publishTimeUpdateData,
      _minPublishTime: 0,
      _encodedVaas: keccak256("someEncodedVaas")
    });
    (limitOrder.account, , , , , , , , , , , ) = limitTradeHandler.limitOrders(address(this), 0);
    assertEq(limitOrder.account, address(0), "Order should be executed and removed from the order list.");

    assertEq(mockTradeService.increasePositionCallCount(), 1);
    (
      address _primaryAccount,
      uint8 _subAccountId,
      uint256 _marketIndex,
      int256 _sizeDelta,
      uint256 _limitPriceE30
    ) = mockTradeService.increasePositionCalls(0);
    assertEq(_primaryAccount, address(this));
    assertEq(_subAccountId, 0);
    assertEq(_marketIndex, 1);
    assertEq(_sizeDelta, 1000 * 1e30);
    assertEq(_limitPriceE30, 1000 * 1e30);
  }
}
