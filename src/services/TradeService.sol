// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { AddressUtils } from "../libraries/AddressUtils.sol";

// interfaces
import { ITradeService } from "./interfaces/ITradeService.sol";
import { IPerpStorage } from "../storages/interfaces/IPerpStorage.sol";
import { IConfigStorage } from "../storages/interfaces/IConfigStorage.sol";
import { IVaultStorage } from "../storages/interfaces/IVaultStorage.sol";
import { ICalculator } from "../contracts/interfaces/ICalculator.sol";
import { IOracleMiddleware } from "../oracle/interfaces/IOracleMiddleware.sol";

contract TradeService is ITradeService {
  using AddressUtils for address;

  // struct
  struct DecreasePositionVars {
    uint256 absPositionSizeE30;
    uint256 priceE30;
    int256 currentPositionSizeE30;
    bool isLongPosition;
  }

  // events
  // @todo - modify event parameters
  event LogDecreasePosition(bytes32 indexed _positionId, uint256 _decreasedSize);

  // state
  address public perpStorage;
  address public vaultStorage;
  address public configStorage;

  constructor(address _perpStorage, address _vaultStorage, address _configStorage) {
    // @todo - sanity check
    perpStorage = _perpStorage;
    vaultStorage = _vaultStorage;
    configStorage = _configStorage;
  }

  function increasePosition(
    address _primaryAccount,
    uint256 _subAccountId,
    uint256 _marketIndex,
    int256 _sizeDelta
  ) external {
    // get the sub-account from the primary account and sub-account ID
    address _subAccount = _getSubAccount(_primaryAccount, _subAccountId);

    // get the position for the given sub-account and market index
    bytes32 _posId = _getPositionId(_subAccount, _marketIndex);
    IPerpStorage.Position memory _position = IPerpStorage(perpStorage).getPositionById(_posId);

    // get the market configuration for the given market index
    IConfigStorage.MarketConfig memory _marketConfig = IConfigStorage(configStorage).getMarketConfigByIndex(
      _marketIndex
    );

    // check size delta
    if (_sizeDelta == 0) revert ITradeService_BadSizeDelta();

    // check allow increase position
    if (!_marketConfig.allowIncreasePosition) revert ITradeService_NotAllowIncrease();

    // determine whether the new size delta is for a long position
    bool _isLong = _sizeDelta > 0;

    bool _isNewPosition = _position.positionSizeE30 == 0;

    // Pre validation
    // Verify that the number of positions has exceeds
    {
      // get the trading configuration.
      IConfigStorage.TradingConfig memory _tradingConfig = IConfigStorage(configStorage).getTradingConfig();

      if (
        _isNewPosition &&
        _tradingConfig.maxPosition < IPerpStorage(perpStorage).getNumberOfSubAccountPosition(_subAccount) + 1
      ) revert ITradeService_BadNumberOfPosition();
    }

    bool _currentPositionIsLong = _position.positionSizeE30 > 0;
    // Verify that the current position has the same exposure direction
    if (!_isNewPosition && _currentPositionIsLong != _isLong) revert ITradeService_BadExposure();

    // Update borrowing rate
    updateBorrowingRate(_marketConfig.assetClass);

    // Get Price market.
    uint256 _priceE30;
    // market validation
    {
      uint256 _lastPriceUpdated;
      uint8 _marketStatus;

      // @todo - update code to use normal get latest price, there is validate price
      (_priceE30, _lastPriceUpdated, _marketStatus) = IOracleMiddleware(IConfigStorage(configStorage).oracle())
        .getLatestPriceWithMarketStatus(
          _marketConfig.assetId,
          _isLong, // if current position is SHORT position, then we use max price
          _marketConfig.priceConfidentThreshold,
          30 // @todo - move trust price age to config, the probleam now is stack too deep at MarketConfig struct
        );

      // Market active represent the market is still listed on our protocol
      if (!_marketConfig.active) revert ITradeService_MarketIsDelisted();

      // if market status is not 2, means that the market is closed or market status has been defined yet
      if (_marketStatus != 2) revert ITradeService_MarketIsClosed();

      // check sub account equity is under MMR
      _subAccountHealthCheck(_subAccount);
    }

    // get the absolute value of the new size delta
    uint256 _absSizeDelta = abs(_sizeDelta);

    // if the position size is zero, set the average price to the current price (new position)
    if (_isNewPosition) {
      _position.avgEntryPriceE30 = _priceE30;
      _position.primaryAccount = _primaryAccount;
      _position.subAccountId = _subAccountId;
      _position.marketIndex = _marketIndex;
    }

    // if the position size is not zero and the new size delta is not zero, calculate the new average price (adjust position)
    if (!_isNewPosition) {
      _position.avgEntryPriceE30 = getPositionNextAveragePrice(
        _marketIndex,
        abs(_position.positionSizeE30),
        _isLong,
        _absSizeDelta,
        _position.avgEntryPriceE30,
        _priceE30
      );
    }

    // TODO: Collect trading fee, borrowing fee, update borrowing rate, collect funding fee, and update funding rate.
    // Collect fee
    collectFee(_subAccount, _marketConfig.assetClass, _position.reserveValueE30, _position.entryBorrowingRate);
    settleFee(_subAccount);

    // update the position size by adding the new size delta
    _position.positionSizeE30 += _sizeDelta;

    {
      IPerpStorage.GlobalAssetClass memory _globalAssetClass = IPerpStorage(perpStorage).getGlobalAssetClassByIndex(
        _marketConfig.assetClass
      );
      _position.entryBorrowingRate = _globalAssetClass.sumBorrowingRate;
    }

    // if the position size is zero after the update, revert the transaction with an error
    if (_position.positionSizeE30 == 0) revert ITradeService_BadPositionSize();

    // calculate the initial margin required for the new position
    uint256 _imr = (_absSizeDelta * _marketConfig.initialMarginFraction) / 1e18;

    {
      // get the amount of free collateral available for the sub-account
      uint256 subAccountFreeCollateral = ICalculator(IConfigStorage(configStorage).calculator()).getFreeCollateral(
        _subAccount
      );
      // if the free collateral is less than the initial margin required, revert the transaction with an error
      if (subAccountFreeCollateral < _imr) revert ITradeService_InsufficientFreeCollateral();
    }

    {
      // calculate the maximum amount of reserve required for the new position
      uint256 _maxReserve = (_imr * _marketConfig.maxProfitRate) / 1e18;
      // increase the reserved amount by the maximum reserve required for the new position
      increaseReserved(_marketConfig.assetClass, _maxReserve);
      _position.reserveValueE30 += _maxReserve;
    }

    // get the global market for the given market index
    IPerpStorage.GlobalMarket memory _globalMarket = IPerpStorage(perpStorage).getGlobalMarketByIndex(_marketIndex);

    {
      // calculate the change in open interest for the new position
      uint256 _changedOpenInterest = (_absSizeDelta * 1e30) / _priceE30; // TODO: use decimal asset
      _position.openInterest += _changedOpenInterest;
      // update gobal market state
      if (_isLong) {
        IPerpStorage(perpStorage).updateGlobalLongMarketById(
          _marketIndex,
          _globalMarket.longPositionSize + _absSizeDelta,
          _globalMarket.longAvgPrice, // todo: recalculate arg price
          _globalMarket.longOpenInterest + _changedOpenInterest
        );
      } else {
        IPerpStorage(perpStorage).updateGlobalShortMarketById(
          _marketIndex,
          _globalMarket.shortPositionSize + _absSizeDelta,
          _globalMarket.shortAvgPrice, // todo: recalculate arg price
          _globalMarket.shortOpenInterest + _changedOpenInterest
        );
      }
    }

    // save the updated position to the storage
    IPerpStorage(perpStorage).savePosition(_subAccount, _posId, _position);
  }

  // @todo - rewrite description
  /// @notice decrease trader position
  /// @param _account - address
  /// @param _subAccountId - address
  /// @param _marketIndex - market index
  /// @param _positionSizeE30ToDecrease - position size to decrease
  function decreasePosition(
    address _account,
    uint256 _subAccountId,
    uint256 _marketIndex,
    uint256 _positionSizeE30ToDecrease
  ) external {
    // prepare
    IConfigStorage.MarketConfig memory _marketConfig = IConfigStorage(configStorage).getMarketConfigByIndex(
      _marketIndex
    );

    address _subAccount = _getSubAccount(_account, _subAccountId);
    bytes32 _positionId = _getPositionId(_subAccount, _marketIndex);
    IPerpStorage.Position memory _position = IPerpStorage(perpStorage).getPositionById(_positionId);

    // init vars
    DecreasePositionVars memory vars = DecreasePositionVars({
      absPositionSizeE30: 0,
      priceE30: 0,
      currentPositionSizeE30: 0,
      isLongPosition: false
    });

    // =========================================
    // | ---------- pre validation ----------- |
    // =========================================

    // if position size is 0 means this position is already closed
    vars.currentPositionSizeE30 = _position.positionSizeE30;
    if (vars.currentPositionSizeE30 == 0) revert ITradeService_PositionAlreadyClosed();

    vars.isLongPosition = vars.currentPositionSizeE30 > 0;

    // convert position size to be uint256
    vars.absPositionSizeE30 = uint256(vars.isLongPosition ? vars.currentPositionSizeE30 : -vars.currentPositionSizeE30);

    // position size to decrease is greater then position size, should be revert
    if (_positionSizeE30ToDecrease > vars.absPositionSizeE30) revert ITradeService_DecreaseTooHighPositionSize();

    // Update borrowing rate
    updateBorrowingRate(_marketConfig.assetClass);

    {
      uint256 _lastPriceUpdated;
      uint8 _marketStatus;

      // @todo - update code to use normal get latest price, there is validate price
      (vars.priceE30, _lastPriceUpdated, _marketStatus) = IOracleMiddleware(IConfigStorage(configStorage).oracle())
        .getLatestPriceWithMarketStatus(
          _marketConfig.assetId,
          !vars.isLongPosition, // if current position is SHORT position, then we use max price
          _marketConfig.priceConfidentThreshold,
          30 // @todo - move trust price age to config, the probleam now is stack too deep at MarketConfig struct
        );

      // Market active represent the market is still listed on our protocol
      if (!_marketConfig.active) revert ITradeService_MarketIsDelisted();

      // if market status is not 2, means that the market is closed or market status has been defined yet
      if (_marketStatus != 2) revert ITradeService_MarketIsClosed();

      // check sub account equity is under MMR
      _subAccountHealthCheck(_subAccount);
    }

    // @todo - update funding & borrowing fee rate
    // @todo - calculate trading, borrowing and funding fee
    // @todo - collect fee
    collectFee(_subAccount, _marketConfig.assetClass, _position.reserveValueE30, _position.entryBorrowingRate);
    settleFee(_subAccount);

    // =========================================
    // | ------ update perp storage ---------- |
    // =========================================
    uint256 _newAbsPositionSizeE30 = vars.absPositionSizeE30 - _positionSizeE30ToDecrease;

    // check position is too tiny
    // @todo - now validate this at 1 USD, design where to keep this config
    //       due to we has problem stack too deep in MarketConfig now
    if (_newAbsPositionSizeE30 > 0 && _newAbsPositionSizeE30 < 1e30) revert ITradeService_TooTinyPosition();

    {
      uint256 _openInterestDelta = (_position.openInterest * _positionSizeE30ToDecrease) / vars.absPositionSizeE30;

      IPerpStorage.GlobalMarket memory _globalMarket = IPerpStorage(perpStorage).getGlobalMarketByIndex(_marketIndex);

      if (vars.isLongPosition) {
        IPerpStorage(perpStorage).updateGlobalLongMarketById(
          _marketIndex,
          _globalMarket.longPositionSize - _positionSizeE30ToDecrease,
          _globalMarket.longAvgPrice, // @todo - recalculate arg price
          _globalMarket.longOpenInterest - _openInterestDelta
        );
      } else {
        IPerpStorage(perpStorage).updateGlobalShortMarketById(
          _marketIndex,
          _globalMarket.shortPositionSize - _positionSizeE30ToDecrease,
          _globalMarket.shortAvgPrice, // @todo - recalculate arg price
          _globalMarket.shortOpenInterest - _openInterestDelta
        );
      }
      IPerpStorage.GlobalState memory _globalState = IPerpStorage(perpStorage).getGlobalState();
      IPerpStorage.GlobalAssetClass memory _globalAssetClass = IPerpStorage(perpStorage).getGlobalAssetClassByIndex(
        _marketConfig.assetClass
      );

      // update global storage
      // to calculate new global reserve = current global reserve - reserve delta (position reserve * (position size delta / current position size))
      _globalState.reserveValueE30 -=
        (_position.reserveValueE30 * _positionSizeE30ToDecrease) /
        vars.absPositionSizeE30;
      _globalAssetClass.reserveValueE30 -=
        (_position.reserveValueE30 * _positionSizeE30ToDecrease) /
        vars.absPositionSizeE30;
      IPerpStorage(perpStorage).updateGlobalState(_globalState);
      IPerpStorage(perpStorage).updateGlobalAssetClass(_marketConfig.assetClass, _globalAssetClass);

      // update position info
      _position.entryBorrowingRate = _globalAssetClass.sumBorrowingRate;
      _position.positionSizeE30 = vars.isLongPosition
        ? int256(_newAbsPositionSizeE30)
        : -int256(_newAbsPositionSizeE30);
      _position.reserveValueE30 =
        (((_newAbsPositionSizeE30 * _marketConfig.initialMarginFraction) / 1e18) * _marketConfig.maxProfitRate) /
        1e18;

      _position.openInterest = _position.openInterest - _openInterestDelta;
      IPerpStorage(perpStorage).savePosition(_subAccount, _positionId, _position);
    }

    // =========================================
    // | ------- settlement position --------- |
    // =========================================
    // @todo - settle profit & loss

    // =========================================
    // | --------- post validation ----------- |
    // =========================================

    // check sub account equity is under MMR
    _subAccountHealthCheck(_subAccount);

    emit LogDecreasePosition(_positionId, _positionSizeE30ToDecrease);
  }

  // @todo - add description
  function _getSubAccount(address _primary, uint256 _subAccountId) internal pure returns (address) {
    if (_subAccountId > 255) revert();
    return address(uint160(_primary) ^ uint160(_subAccountId));
  }

  // @todo - add description
  function _getPositionId(address _account, uint256 _marketIndex) internal pure returns (bytes32) {
    return keccak256(abi.encodePacked(_account, _marketIndex));
  }

  /// @notice Calculates the next average price of a position, given the current position details and the next price.
  /// @param marketIndex The index of the market.
  /// @param size The current size of the position.
  /// @param isLong Whether the position is long or short.
  /// @param sizeDelta The size difference between the current position and the next position.
  /// @param averagePrice The current average price of the position.
  /// @param nextPrice The next price of the position.
  /// @return The next average price of the position.
  function getPositionNextAveragePrice(
    uint256 marketIndex,
    uint256 size,
    bool isLong,
    uint256 sizeDelta,
    uint256 averagePrice,
    uint256 nextPrice
  ) internal view returns (uint256) {
    // Get the delta and isProfit value from the getDelta function
    (bool isProfit, uint256 delta) = getDelta(marketIndex, size, isLong, averagePrice);
    // Calculate the next size and divisor
    uint256 nextSize = size + sizeDelta;
    uint256 divisor;
    if (isLong) {
      divisor = isProfit ? nextSize + delta : nextSize - delta;
    } else {
      divisor = isProfit ? nextSize - delta : nextSize + delta;
    }

    // Calculate the next average price of the position
    return (nextPrice * nextSize) / divisor;
  }

  /// @notice Calculates the delta between average price and mark price, based on the size of position and whether the position is profitable.
  /// @param _marketIndex The
  /// @param _size The size of the position.
  /// @param _isLong The
  /// @param _averagePrice The average price of the position.
  /// @return isProfit A boolean value indicating whether the position is profitable or not.
  /// @return delta The Profit between the average price and the fixed price, adjusted for the size of the order.
  function getDelta(
    uint256 _marketIndex,
    uint256 _size,
    bool _isLong,
    uint256 _averagePrice
  ) public view returns (bool, uint256) {
    // Check for invalid input: averagePrice cannot be zero.
    if (_averagePrice == 0) revert ITradeService_InvalidAveragePrice();

    // Get Price market.
    IConfigStorage.MarketConfig memory marketConfig = IConfigStorage(configStorage).getMarketConfigByIndex(
      _marketIndex
    );
    (uint256 price, ) = IOracleMiddleware(IConfigStorage(configStorage).oracle()).getLatestPrice(
      marketConfig.assetId,
      _isLong,
      marketConfig.priceConfidentThreshold,
      0
    );

    // Calculate the difference between the average price and the fixed price.
    uint256 priceDelta;
    unchecked {
      priceDelta = _averagePrice > price ? _averagePrice - price : price - _averagePrice;
    }

    // Calculate the delta, adjusted for the size of the order.
    uint256 delta = (_size * priceDelta) / _averagePrice;

    // Determine if the position is profitable or not based on the averagePrice and the mark price.
    bool isProfit;
    if (_isLong) {
      isProfit = price > _averagePrice;
    } else {
      isProfit = price < _averagePrice;
    }

    // Return the values of isProfit and delta.
    return (isProfit, delta);
  }

  /// @notice This function increases the reserve value
  /// @param _assetClassIndex The index of asset class.
  /// @param _reservedValue The amount by which to increase the reserve value.
  function increaseReserved(uint256 _assetClassIndex, uint256 _reservedValue) internal {
    // Get the total TVL
    uint256 tvl = ICalculator(IConfigStorage(configStorage).calculator()).getPLPValueE30(true);

    // Retrieve the global state
    IPerpStorage.GlobalState memory _globalState = IPerpStorage(perpStorage).getGlobalState();

    // Retrieve the global asset class
    IPerpStorage.GlobalAssetClass memory _globalAssetClass = IPerpStorage(perpStorage).getGlobalAssetClassByIndex(
      _assetClassIndex
    );

    // get the liquidity configuration
    IConfigStorage.LiquidityConfig memory _liquidityConfig = IConfigStorage(configStorage).getLiquidityConfig();

    // Increase the reserve value by adding the reservedValue
    _globalState.reserveValueE30 += _reservedValue;
    _globalAssetClass.reserveValueE30 += _reservedValue;

    // Check if the new reserve value exceeds the % of AUM, and revert if it does
    if ((tvl * _liquidityConfig.maxPLPUtilization) < _globalState.reserveValueE30 * 1e18) {
      revert ITradeService_InsufficientLiquidity();
    }

    // Update the new reserve value in the IPerpStorage contract
    IPerpStorage(perpStorage).updateGlobalState(_globalState);
    IPerpStorage(perpStorage).updateGlobalAssetClass(_assetClassIndex, _globalAssetClass);
  }

  function abs(int256 x) private pure returns (uint256) {
    return uint256(x >= 0 ? x : -x);
  }

  // @todo - add description
  function _subAccountHealthCheck(address _subAccount) internal {
    ICalculator _calculator = ICalculator(IConfigStorage(configStorage).calculator());
    // check sub account is healty
    uint256 _subAccountEquity = _calculator.getEquity(_subAccount);
    // maintenance margin requirement (MMR) = position size * maintenance margin fraction
    // note: maintenanceMarginFraction is 1e18
    uint256 _mmr = _calculator.getMMR(_subAccount);

    // if sub account equity < MMR, then trader couln't decrease position
    if (_subAccountEquity < _mmr) revert ITradeService_SubAccountEquityIsUnderMMR();
  }

  /// @notice This function updates the borrowing rate for the given asset class index.
  /// @param _assetClassIndex The index of the asset class.
  function updateBorrowingRate(uint256 _assetClassIndex) public {
    // Get the trading config, asset class config, and global asset class for the given asset class index.
    IConfigStorage.TradingConfig memory _tradingConfig = IConfigStorage(configStorage).getTradingConfig();
    IPerpStorage.GlobalAssetClass memory _globalAssetClass = IPerpStorage(perpStorage).getGlobalAssetClassByIndex(
      _assetClassIndex
    );

    // If last borrowing time is 0, set it to the nearest funding interval time and return.
    if (_globalAssetClass.lastBorrowingTime == 0) {
      _globalAssetClass.lastBorrowingTime =
        (block.timestamp / _tradingConfig.fundingInterval) *
        _tradingConfig.fundingInterval;
      IPerpStorage(perpStorage).updateGlobalAssetClass(_assetClassIndex, _globalAssetClass);
      return;
    }

    // If block.timestamp is not passed the next funding interval, skip updating
    if (_globalAssetClass.lastBorrowingTime + _tradingConfig.fundingInterval <= block.timestamp) {
      // update borrowing rate
      uint256 borrowingRate = getNextBorrowingRate(_assetClassIndex);
      _globalAssetClass.sumBorrowingRate += borrowingRate;
      _globalAssetClass.lastBorrowingTime =
        (block.timestamp / _tradingConfig.fundingInterval) *
        _tradingConfig.fundingInterval;
    }
    IPerpStorage(perpStorage).updateGlobalAssetClass(_assetClassIndex, _globalAssetClass);
  }

  /// @notice This function takes an asset class index as input and returns the next borrowing rate for that asset class.
  /// @param _assetClassIndex The index of the asset class.
  /// @return _nextBorrowingRate The next borrowing rate for the asset class.
  function getNextBorrowingRate(uint256 _assetClassIndex) public view returns (uint256 _nextBorrowingRate) {
    // Get the trading config, asset class config, and global asset class for the given asset class index.
    IConfigStorage.TradingConfig memory _tradingConfig = IConfigStorage(configStorage).getTradingConfig();
    IConfigStorage.AssetClassConfig memory _assetClassConfig = IConfigStorage(configStorage).getAssetClassConfigByIndex(
      _assetClassIndex
    );
    IPerpStorage.GlobalAssetClass memory _globalAssetClass = IPerpStorage(perpStorage).getGlobalAssetClassByIndex(
      _assetClassIndex
    );
    // Get the calculator.
    ICalculator _calculator = ICalculator(IConfigStorage(configStorage).calculator());
    // Get the PLP TVL.
    uint256 plpTVL = _calculator.getPLPValueE30(false); // TODO: make sure to use price

    // If block.timestamp not pass the next funding time, return 0.
    if (_globalAssetClass.lastBorrowingTime + _tradingConfig.fundingInterval > block.timestamp) return 0;
    // If PLP TVL is 0, return 0.
    if (plpTVL == 0) return 0;

    // Calculate the number of funding intervals that have passed since the last borrowing time.
    uint256 intervals = (block.timestamp - _globalAssetClass.lastBorrowingTime) / _tradingConfig.fundingInterval;

    // Calculate the next borrowing rate based on the asset class config, global asset class reserve value, and intervals.
    return (_assetClassConfig.baseBorrowingRate * _globalAssetClass.reserveValueE30 * intervals) / plpTVL;
  }

  /// @notice Calculates the borrowing fee for a given asset class based on the reserved value, entry borrowing rate, and current sum borrowing rate of the asset class.
  /// @param _assetClassIndex The index of the asset class for which to calculate the borrowing fee.
  /// @param _reservedValue The reserved value of the asset class.
  /// @param _entryBorrowingRate The entry borrowing rate of the asset class.
  /// @return borrowingFee The calculated borrowing fee for the asset class.
  function getBorrowingFee(
    uint256 _assetClassIndex,
    uint256 _reservedValue,
    uint256 _entryBorrowingRate
  ) public view returns (uint256 borrowingFee) {
    // Get the global asset class.
    IPerpStorage.GlobalAssetClass memory _globalAssetClass = IPerpStorage(perpStorage).getGlobalAssetClassByIndex(
      _assetClassIndex
    );
    // Calculate borrowing rate.
    uint256 _borrowingRate = _globalAssetClass.sumBorrowingRate - _entryBorrowingRate;
    // Calculate the borrowing fee based on reserved value, borrowing rate.
    return (_reservedValue * _borrowingRate) / 1e18;
  }

  /// @notice This function collect fee is collect borrowing fee, funding fee
  /// @param _subAccount The sub-account from which to collect the fee.
  /// @param _assetClassIndex The index of the asset class for which to calculate the borrowing fee.
  /// @param _reservedValue The reserved value of the asset class.
  /// @param _entryBorrowingRate The entry borrowing rate of the asset class.
  function collectFee(
    address _subAccount,
    uint256 _assetClassIndex,
    uint256 _reservedValue,
    uint256 _entryBorrowingRate
  ) public {
    // Get the debt fee of the sub-account
    uint256 feeUsd = IPerpStorage(perpStorage).getSubAccountFee(_subAccount);
    // Calculate the borrowing fee
    uint256 borrowingFee = getBorrowingFee(_assetClassIndex, _reservedValue, _entryBorrowingRate);

    // Accumulate fee
    feeUsd += borrowingFee;
    // Update the sub-account's debt fee balance
    IPerpStorage(perpStorage).updateSubAccountFee(_subAccount, feeUsd);
  }

  function settleFee(address _subAccount) public {
    // Retrieve the debt fee amount for the sub-account
    uint256 feeUsd = IPerpStorage(perpStorage).getSubAccountFee(_subAccount);
    // If there's no fee to settle, return early
    if (feeUsd == 0) return;

    // Retrieve the trading configuration and list of plp tokens
    IConfigStorage.TradingConfig memory _tradingConfig = IConfigStorage(configStorage).getTradingConfig();
    address[] memory _plpTokens = IConfigStorage(configStorage).getPlpTokens();

    // Loop through all the plp tokens for the sub-account
    for (uint256 i = 0; i < _plpTokens.length; ) {
      // Retrieve the balance of the plp token for the sub-account
      uint256 balance = IVaultStorage(vaultStorage).traderBalances(_subAccount, _plpTokens[i]);

      // If the sub-account has a balance of the plp token
      if (balance != 0) {
        // Retrieve the latest price and confident threshold of the plp token
        (uint256 price, ) = IOracleMiddleware(IConfigStorage(configStorage).oracle()).unsafeGetLatestPrice(
          _plpTokens[i].toBytes32(),
          false,
          IConfigStorage(configStorage).getMarketConfigByToken(_plpTokens[i]).priceConfidentThreshold
        );
        // Calculate the fee amount in the plp token
        uint256 _feeToken = (feeUsd * (10 ** ERC20(_plpTokens[i]).decimals())) / price;
        // Calculate the balance value of the plp token in USD
        uint256 _balanceValue = (balance * price) / (10 ** ERC20(_plpTokens[i]).decimals());
        uint repayFeeToken = 0;

        // Repay the fee amount and subtract it from the balance
        if (balance > _feeToken) {
          repayFeeToken = _feeToken;
          balance -= _feeToken;
          feeUsd = 0;
        } else {
          repayFeeToken = balance;
          balance = 0;
          feeUsd -= _balanceValue;
        }

        // Calculate the developer fee amount in the plp token
        uint256 devFeeToken = (repayFeeToken * _tradingConfig.devFeeRate) / 1e18;
        // Add the developer fee to the vault
        IVaultStorage(vaultStorage).addDevFee(_plpTokens[i], devFeeToken);
        // Add the remaining fee amount to the plp liquidity in the vault
        IVaultStorage(vaultStorage).addPLPLiquidity(_plpTokens[i], repayFeeToken - devFeeToken);
        // Update the sub-account balance for the plp token in the vault
        IVaultStorage(vaultStorage).setTraderBalance(_subAccount, _plpTokens[i], balance);
      }

      {
        unchecked {
          ++i;
        }
      }
    }

    // Update the fee amount for the sub-account in the PerpStorage contract
    IPerpStorage(perpStorage).updateSubAccountFee(_subAccount, feeUsd);
  }
}
