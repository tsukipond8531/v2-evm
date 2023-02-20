// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import { LimitTradeHandler_Base, IPerpStorage } from "./LimitTradeHandler_Base.t.sol";
import { ILimitTradeHandler } from "../../../src/handlers/interfaces/ILimitTradeHandler.sol";

contract LimitTradeHandler_CancelOrder is LimitTradeHandler_Base {
  function setUp() public override {
    super.setUp();
  }

  function testRevert_cancel_NonExistentOrder() external {
    vm.expectRevert(abi.encodeWithSignature("ILimitTradeHandler_NonExistentOrder()"));
    limitTradeHandler.cancelOrder({
      _orderType: ILimitTradeHandler.OrderType.INCREASE,
      _subAccountId: 0,
      _orderIndex: 0
    });
  }

  function testCorrectness_cancelOrder() external {
    uint256 balanceBefore = address(this).balance;

    limitTradeHandler.createOrder{ value: 0.1 ether }({
      _orderType: ILimitTradeHandler.OrderType.INCREASE,
      _subAccountId: 0,
      _marketIndex: 1,
      _sizeDelta: 1000 * 1e30,
      _triggerPrice: 1000 * 1e30,
      _triggerAboveThreshold: true,
      _executionFee: 0.1 ether
    });

    ILimitTradeHandler.LimitOrder memory limitOrder;
    (, limitOrder.account, , , , , , , ) = limitTradeHandler.limitOrders(address(this), 0);
    assertEq(limitOrder.account, address(this));

    limitTradeHandler.cancelOrder({
      _orderType: ILimitTradeHandler.OrderType.INCREASE,
      _subAccountId: 0,
      _orderIndex: 0
    });

    (, limitOrder.account, , , , , , , ) = limitTradeHandler.limitOrders(address(this), 0);
    assertEq(limitOrder.account, address(0));
  }
}
