const LimitOrderManager = artifacts.require("LimitOrderManager");
const LimitOrderMonitor = artifacts.require("LimitOrderMonitor");
const Kromatika = artifacts.require("Kromatika");
const {deployProxy} = require("@openzeppelin/truffle-upgrades");

module.exports = async function (deployer, network, accounts) {

  const wrappedETHAddress = process.env.WETH;
  const positionManager = process.env.UNISWAP_POSITION_MANAGER;
  const uniswapFactory = process.env.UNISWAP_FACTORY;
  const quoterV2 = process.env.UNISWAP_QUOTER;

  const limitOrderManagerInstance = await LimitOrderManager.deployed();

  const kromatikaInstance = await Kromatika.deployed();

  //_maxBatchSize = 20, monitorSize=500, monitorInterval = 1 block, monitorFee = 10 %
  await deployProxy(LimitOrderMonitor,
      [limitOrderManagerInstance.address, positionManager, uniswapFactory,
        wrappedETHAddress, kromatikaInstance.address, quoterV2,
        20, 500, 1, 10000],
      {deployer});

  const limitOrderMonitorInstance = await LimitOrderMonitor.deployed()
  await limitOrderManagerInstance.setMonitors([limitOrderMonitorInstance.address]);
};
