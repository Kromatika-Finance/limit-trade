const LimitOrderManager = artifacts.require("LimitOrderManager");
const Kromatika = artifacts.require("Kromatika");
const LimitManagerUtils = artifacts.require("ManagerUtils");
const {deployProxy} = require("@openzeppelin/truffle-upgrades");

module.exports = async function (deployer, network, accounts) {

  const wrappedETHAddress = process.env.WETH;
  const uniswapFactory = process.env.UNISWAP_FACTORY;
  const uniswapQuoter = process.env.UNISWAP_QUOTER;
  const feeAddress = process.env.FEE_ADDRESS;

  const kromatikaInstance = await Kromatika.deployed();

  await deployProxy(LimitManagerUtils, [], {deployer});
  const managerUtilsInstance = await LimitManagerUtils.deployed();

  // 600k gas usage, 10% protocol fee
  await deployProxy(LimitOrderManager,
      [uniswapFactory, uniswapQuoter, wrappedETHAddress, managerUtilsInstance.address, kromatikaInstance.address,
        feeAddress, 400000, 10000],
      {deployer, unsafeAllow: ['delegatecall']});
};
