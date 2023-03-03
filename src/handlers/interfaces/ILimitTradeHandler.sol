// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.18;

interface ILimitTradeHandler {
  /**
   * Errors
   */
  error ILimitTradeHandler_InvalidAddress();
  error ILimitTradeHandler_InsufficientExecutionFee();
  error ILimitTradeHandler_IncorrectValueTransfer();
  error ILimitTradeHandler_NotWhitelisted();
  error ILimitTradeHandler_BadSubAccountId();
  error ILimitTradeHandler_InvalidSender();
  error ILimitTradeHandler_NonExistentOrder();
  error ILimitTradeHandler_MarketIsClosed();
  error ILimitTradeHandler_InvalidPriceForExecution();
  error ILimitTradeHandler_WrongSizeDelta();
  error ILimitTradeHandler_UnknownOrderType();
  error ILimitTradeHandler_MaxExecutionFee();

  /**
   * Structs
   */
  struct LimitOrder {
    address account;
    address tpToken;
    bool triggerAboveThreshold;
    bool reduceOnly;
    int256 sizeDelta;
    uint256 subAccountId;
    uint256 marketIndex;
    uint256 triggerPrice;
    uint256 executionFee;
  }

  /**
   * States
   */

  function limitOrders(
    address _subAccount,
    uint256 _index
  )
    external
    returns (
      address _account,
      address _tpToken,
      bool _triggerAboveThreshold,
      bool _reduceOnly,
      int256 _sizeDelta,
      uint256 _subAccountId,
      uint256 _marketIndex,
      uint256 _triggerPrice,
      uint256 _executionFee
    );

  /**
   * Setters
   */
  function setTradeService(address _newTradeService) external;

  function setMinExecutionFee(uint256 _newMinExecutionFee) external;

  function setOrderExecutor(address _executor, bool _isAllow) external;

  /**
   * Functions
   */
  function createOrder(
    uint256 _subAccountId,
    uint256 _marketIndex,
    int256 _sizeDelta,
    uint256 _triggerPrice,
    bool _triggerAboveThreshold,
    uint256 _executionFee,
    bool _reduceOnly,
    address _tpToken
  ) external payable;

  function executeOrder(
    address _account,
    uint256 _subAccountId,
    uint256 _orderIndex,
    address payable _feeReceiver,
    bytes[] memory _priceData
  ) external;

  function cancelOrder(uint256 _subAccountId, uint256 _orderIndex) external;

  function updateOrder(
    uint256 _subAccountId,
    uint256 _orderIndex,
    int256 _sizeDelta,
    uint256 _triggerPrice,
    bool _triggerAboveThreshold,
    bool _reduceOnly,
    address _tpToken
  ) external;

  function validatePositionOrderPrice(
    bool _triggerAboveThreshold,
    uint256 _triggerPrice,
    uint256 _marketIndex,
    int256 _sizeDelta,
    bool _maximizePrice,
    bool _revertOnError
  ) external view returns (uint256, bool);
}
