// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import { BaseIntTest_WithActions } from "@hmx-test/integration/99_BaseIntTest_WithActions.i.sol";

import { LiquidityTester } from "@hmx-test/testers/LiquidityTester.sol";

import { IPerpStorage } from "@hmx/storages/interfaces/IPerpStorage.sol";

import { PositionTester02 } from "@hmx-test/testers/PositionTester02.sol";

contract TC09 is BaseIntTest_WithActions {
  bytes[] internal updatePriceData;

  function testCorrectness_TC09() external {
    bytes[] memory priceData = new bytes[](0);

    // T0: Initialized state
    {
      //deal with out of gas
      vm.deal(ALICE, 10 ether);
      vm.deal(BOB, 10 ether);
      vm.deal(BOT, 10 ether);

      usdt.mint(ALICE, 100_000 * 1e6);
      wbtc.mint(ALICE, 0.5 * 1e8);

      wbtc.mint(BOB, 10 * 1e8);
    }

    vm.warp(block.timestamp + 1);
    {
      // BOB add liquidity
      addLiquidity(BOB, wbtc, 10 * 1e8, executionOrderFee, priceData, true);
    }

    vm.warp(block.timestamp + 1);
    {
      // Alice deposits 10,000(USD) of WBTC
      depositCollateral(ALICE, 0, wbtc, 0.05 * 1e8);
      depositCollateral(ALICE, 1, wbtc, 0.05 * 1e8);
    }

    vm.warp(block.timestamp + 1);
    // T1: Alice buy long JPYUSD 100,000 USD at 0.008 USD
    {
      updatePriceData = new bytes[](3);
      updatePriceData[0] = _createPriceFeedUpdateData(jpyAssetId, 125 * 1e3, 0);
      updatePriceData[1] = _createPriceFeedUpdateData(usdcAssetId, 1 * 1e8, 0);
      updatePriceData[2] = _createPriceFeedUpdateData(wbtcAssetId, 20_000 * 1e8, 0);

      // buy
      marketBuy(ALICE, 0, jpyMarketIndex, 100_000 * 1e30, address(wbtc), updatePriceData);
      marketBuy(ALICE, 1, wbtcMarketIndex, 10_000 * 1e30, address(wbtc), updatePriceData);
    }

    // T2: Alice buy the position for 20 mins, JPYUSD dumped hard to 0.007945967421533571712355979340 USD. This makes Alice account went below her kill level
    vm.warp(block.timestamp + (20 * MINUTES));
    {
      uint256 traderBalanceBefore = vaultStorage.traderBalances(ALICE, address(wbtc));
      uint256 protocolFeesBefore = vaultStorage.protocolFees(address(wbtc));
      uint256 devFeesBefore = vaultStorage.devFees(address(wbtc));
      uint256 plpLiquidityBefore = vaultStorage.plpLiquidity(address(wbtc));

      updatePriceData = new bytes[](3);
      updatePriceData[0] = _createPriceFeedUpdateData(jpyAssetId, 125.85 * 1e3, 0);
      updatePriceData[1] = _createPriceFeedUpdateData(usdcAssetId, 1 * 1e8, 0);
      updatePriceData[2] = _createPriceFeedUpdateData(wbtcAssetId, 20_000 * 1e8, 0);

      liquidate(getSubAccount(ALICE, 0), updatePriceData);
      /*
       * |        |                 loss                 |   trading   |        borrowing     |       funding     | liquidation |     Total   | unit |
       * |--------|--------------------------------------|-------------|----------------------|-------------------|-------------|-------------|------|
       * |     P1 |  -675.407230830353595550258252819338 |          30 |   1.4623871614844526 | 15.99999999996000 |           5 |             |  USD |
       * |--------|--------------------------------------|-------------|----------------------|-------------------|-------------|-------------|------|
       * |  Total |  -675.407230830353595550258252819338 |          30 |   1.4623871614844526 | 15.99999999996000 |           5 |             |  USD |
       * |--------|--------------------------------------|-------------|----------------------|-------------------|-------------|-------------|------|
       * |  Total |                           0.03377036 |      0.0015 |           0.00007311 |        0.00079999 |     0.00025 |  0.03639346 |  BTC |
       * |--------|--------------------------------------|-------------|----------------------|-------------------|-------------|-------------|------|
       * |    Dev |                                      |    0.000225 |           0.00001096 |                   |             |  0.00023596 |  BTC |
       * |--------|--------------------------------------|-------------|----------------------|-------------------|-------------|-------------|------|
       * |    PLP |                           0.03377036 |             |           0.00006215 |                   |             |  0.03383251 |  BTC |
       * |--------|--------------------------------------|-------------|----------------------|-------------------|-------------|-------------|------|
       * |  P-fee |                                      |    0.001275 |                      |                   |             |    0.001275 |  BTC |
       * |--------|--------------------------------------|-------------|----------------------|-------------------|-------------|-------------|------|
       * |    liq |                                      |             |                      |                   |     0.00025 |     0.00025 |  BTC |
       */
      address aliceSubAccount1 = getSubAccount(ALICE, 0);
      assertSubAccountTokenBalance(ALICE, address(wbtc), true, traderBalanceBefore - 0.03639346 * 1e8);
      assertVaultsFees(
        address(wbtc),
        protocolFeesBefore + (0.001275 * 1e8),
        devFeesBefore + (0.00023596 * 1e8),
        0.00079999 * 1e8
      );
      assertPLPLiquidity(address(wbtc), plpLiquidityBefore + 0.03383251 * 1e8);
      assertSubAccountTokenBalance(BOT, address(wbtc), true, 0.00025 * 1e8);
      assertNumberOfPosition(aliceSubAccount1, 0);
      assertPositionInfoOf(aliceSubAccount1, jpyMarketIndex, 0, 0, 0, 0, 0, 0);
      assertMarketLongPosition(jpyMarketIndex, 0, 0);
    }
    {
      vm.expectRevert(abi.encodeWithSignature("ILiquidationService_AccountHealthy()"));
      liquidate(getSubAccount(ALICE, 1), priceData);

      address aliceSubAccount2 = getSubAccount(ALICE, 1);
      assertNumberOfPosition(aliceSubAccount2, 1);
    }
  }
}