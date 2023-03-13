// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import { Owned } from "@hmx/base/Owned.sol";
import { IPyth, PythStructs } from "pyth-sdk-solidity/IPyth.sol";
import { IPythAdapter } from "./interfaces/IPythAdapter.sol";

contract PythAdapter is Owned, IPythAdapter {
  // errors
  error PythAdapter_BrokenPythPrice();
  error PythAdapter_ConfidenceRatioTooHigh();
  error PythAdapter_OnlyUpdater();
  error PythAdapter_UnknownAssetId();

  // state variables
  IPyth public pyth;
  // mapping of our asset id to Pyth's price id
  mapping(bytes32 => IPythAdapter.PythPriceConfig) public configs;

  // whitelist mapping of price updater
  mapping(address => bool) public isUpdater;

  // events
  event SetConfig(bytes32 indexed _assetId, bytes32 _pythPriceId, bool _inverse);
  event SetUpdater(address indexed _account, bool _isActive);

  constructor(IPyth _pyth) {
    pyth = _pyth;

    // Sanity
    pyth.getValidTimePeriod();
  }

  /// @notice Set the Pyth price id for the given asset.
  /// @param _assetId The asset address to set.
  /// @param _pythPriceId The Pyth price id to set.
  function setConfig(bytes32 _assetId, bytes32 _pythPriceId, bool _inverse) external onlyOwner {
    PythPriceConfig memory _config = configs[_assetId];

    _config.pythPriceId = _pythPriceId;
    _config.inverse = _inverse;
    emit SetConfig(_assetId, _pythPriceId, _inverse);

    configs[_assetId] = _config;
  }

  /// @notice convert Pyth's price to uint256.
  /// @dev This is partially taken from https://github.com/pyth-network/pyth-crosschain/blob/main/target_chains/ethereum/examples/oracle_swap/contract/src/OracleSwap.sol#L92
  /// @param _priceStruct The Pyth's price struct to convert.
  /// @param _isMax Whether to use the max price or min price.
  /// @param _targetDecimals The target decimals to convert to.
  /// @param _shouldInvert Whether should invert(^-1) the final result or not.
  function _convertToUint256(
    PythStructs.Price memory _priceStruct,
    bool _isMax,
    uint8 _targetDecimals,
    bool _shouldInvert
  ) private pure returns (uint256) {
    if (_priceStruct.price <= 0 || _priceStruct.expo > 0 || _priceStruct.expo < -255) {
      revert PythAdapter_BrokenPythPrice();
    }

    uint8 _priceDecimals = uint8(uint32(-1 * _priceStruct.expo));

    // Basicly, this is _isMax XOR _shouldInvert
    //  _isMax  |  _shouldInvert  |  operator
    //  true    |  true           |  -
    //  true    |  false          |  +
    //  false   |  true           |  +
    //  false   |  false          |  -
    uint64 _price = _isMax == _shouldInvert
      ? uint64(_priceStruct.price) - _priceStruct.conf
      : uint64(_priceStruct.price) + _priceStruct.conf;

    uint256 _price256;
    if (_targetDecimals - _priceDecimals >= 0) {
      _price256 = uint256(_price) * 10 ** uint32(_targetDecimals - _priceDecimals);
    } else {
      _price256 = uint256(_price) / 10 ** uint32(_priceDecimals - _targetDecimals);
    }

    if (!_shouldInvert) {
      return _price256;
    }

    // Quote inversion. This is an intention to support the price like USD/JPY.
    {
      // Safe div 0 check, possible when _priceStruct.price == _priceStruct.conf
      if (_price256 == 0) return 0;

      // Formula: inverted price = 10^2N / priceEN, when N = target decimal
      //
      // Example: Given _targetDecimals = 30, inverted quote price can be caluclated as followed.
      // inverted price = 10^60 / priceE30
      return 10 ** uint32(_targetDecimals * 2) / _price256;
    }
  }

  /// @notice Validate Pyth's confidence with given threshold. Revert if confidence ratio is too high.
  /// @dev To bypass the confidence check, the user can submit threshold = 1 ether
  /// @param _priceStruct The Pyth's price struct to convert.
  /// @param _confidenceThreshold The acceptable threshold confidence ratio. ex. _confidenceRatio = 0.01 ether means 1%
  function _validateConfidence(PythStructs.Price memory _priceStruct, uint32 _confidenceThreshold) private pure {
    if (_priceStruct.price < 0) revert PythAdapter_BrokenPythPrice();

    // Revert if confidence ratio is too high
    if (_priceStruct.conf * 1e6 > _confidenceThreshold * uint64(_priceStruct.price))
      revert PythAdapter_ConfidenceRatioTooHigh();
  }

  /// @notice Get the latest price of the given asset. Returned price is in 30 decimals.
  /// @dev The price returns here can be staled.
  /// @param _assetId The asset id to get price.
  /// @param _isMax Whether to get the max price.
  /// @param _confidenceThreshold The acceptable threshold confidence ratio. ex. _confidenceRatio = 0.01 ether means 1%
  function getLatestPrice(
    bytes32 _assetId,
    bool _isMax,
    uint32 _confidenceThreshold
  ) external view returns (uint256, int32, uint256) {
    // SLOAD
    IPythAdapter.PythPriceConfig memory _config = configs[_assetId];

    if (_config.pythPriceId == bytes32(0)) revert PythAdapter_UnknownAssetId();
    PythStructs.Price memory _price = pyth.getPriceUnsafe(_config.pythPriceId);
    _validateConfidence(_price, _confidenceThreshold);

    return (_convertToUint256(_price, _isMax, 30, _config.inverse), _price.expo, _price.publishTime);
  }
}
