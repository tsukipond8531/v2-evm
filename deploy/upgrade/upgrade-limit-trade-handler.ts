import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import { ethers, tenderly, upgrades, network } from "hardhat";
import { getConfig, writeConfigFile } from "../utils/config";
import { getImplementationAddress } from "@openzeppelin/upgrades-core";

const BigNumber = ethers.BigNumber;
const config = getConfig();

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const deployer = (await ethers.getSigners())[0];

  const Contract = await ethers.getContractFactory("LimitTradeHandler", deployer);
  const TARGET_ADDRESS = config.handlers.bot;

  console.log(`> Preparing to upgrade LimitTradeHandler`);
  const newImplementation = await upgrades.prepareUpgrade(TARGET_ADDRESS, Contract);
  console.log(`> Done`);

  console.log(`> New LimitTradeHandler Implementation address: ${newImplementation}`);
  const upgradeTx = await upgrades.upgradeProxy(TARGET_ADDRESS, Contract);
  console.log(`> ⛓ Tx is submitted: ${upgradeTx.deployTransaction.hash}`);
  console.log(`> Waiting for tx to be mined...`);
  await upgradeTx.deployTransaction.wait(3);
  console.log(`> Tx is mined!`);

  console.log(`> Verify contract on Tenderly`);
  await tenderly.verify({
    address: newImplementation.toString(),
    name: "LimitTradeHandler",
  });
};

export default func;
func.tags = ["UpgradeLimitTradeHandler"];