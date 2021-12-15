const LimitOrderManager = artifacts.require("LimitOrderManager");
const LimitOrderMonitor = artifacts.require("LimitOrderMonitorETH");
const ManagerUtils = artifacts.require("ManagerUtils");
const Kromatika = artifacts.require("Kromatika");
const {deployProxy} = require("@openzeppelin/truffle-upgrades");

module.exports = async function (deployer, network, accounts) {

  // const uniswapFactory = process.env.UNISWAP_FACTORY;
  // const router = process.env.UNISWAP_ROUTER;
  // const wrappedETHAddress = process.env.WETH;
  //
  // const limitOrderManagerInstance = await LimitOrderManager.deployed();
  // const kromatikaInstance = await Kromatika.deployed();
  // const WETHExtendedInstance = await WETHExtended.deployed();
  //
  // //_maxBatchSize = 10, monitorSize=20, monitorInterval = 1 block,
  // // monitorFee = 10 % (this needs to be in a global config); the same % should be applied in the estimation
  // await deployProxy(LimitOrderMonitor,
  //     [limitOrderManagerInstance.address, uniswapFactory, kromatikaInstance.address, accounts[0],
  //       10, 100, 1, 10000, router, wrappedETHAddress, WETHExtendedInstance.address],
  //     {deployer, unsafeAllow: ["external-library-linking", 'delegatecall', 'state-variable-immutable', 'state-variable-assignment']});
  //
  //
  // const limitOrderMonitorInstance = await LimitOrderMonitor.deployed()
  // await limitOrderManagerInstance.addMonitor(limitOrderMonitorInstance.address);
};
