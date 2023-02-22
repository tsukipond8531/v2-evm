// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

interface ICrossMarginHandler {
  /**
   * Errors
   */
  error ICrossMarginHandler_InvalidAddress();

  function depositCollateral(address _account, uint256 _subAccountId, address _token, uint256 _amount) external;

  function withdrawCollateral(
    address _account,
    uint256 _subAccountId,
    address _token,
    uint256 _amount,
    bytes[] memory _priceData
  ) external;
}
