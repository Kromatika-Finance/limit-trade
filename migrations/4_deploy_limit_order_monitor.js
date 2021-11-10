const LimitOrderManager = artifacts.require("LimitOrderManager");
const LimitOrderMonitor = artifacts.require("LimitOrderMonitorChainlink");
const Kromatika = artifacts.require("Kromatika");
const {deployProxy} = require("@openzeppelin/truffle-upgrades");

module.exports = async function (deployer, network, accounts) {

  const uniswapFactory = process.env.UNISWAP_FACTORY;
  const router = process.env.UNISWAP_ROUTER;
  const linkAddress = process.env.LINK;
  const wrappedETHAddress = process.env.WETH;

  const limitOrderManagerInstance = await LimitOrderManager.deployed();
  const kromatikaInstance = await Kromatika.deployed();

  //_maxBatchSize = 10, monitorSize=20, monitorInterval = 1 block,
  // monitorFee = 20 % (this needs to be in a global config); the same % should be applied in the estimation
  await deployProxy(LimitOrderMonitor,
      [limitOrderManagerInstance.address, uniswapFactory, kromatikaInstance.address,
        10, 100, 1, 20000, router, wrappedETHAddress, linkAddress],
      {deployer});

  const limitOrderMonitorInstance = await LimitOrderMonitor.deployed()
  await limitOrderManagerInstance.setMonitors([limitOrderMonitorInstance.address]);
};
