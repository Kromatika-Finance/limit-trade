const LimitOrderManager = artifacts.require("OpLimitOrderManager");
const LimitOrderMonitor = artifacts.require("LimitOrderMonitor");
const Kromatika = artifacts.require("Kromatika");
const {deployProxy} = require("@openzeppelin/truffle-upgrades");

module.exports = async function (deployer, network, accounts) {

  const uniswapFactory = process.env.UNISWAP_FACTORY;

  const limitOrderManagerInstance = await LimitOrderManager.deployed();
  const kromatikaInstance = await Kromatika.deployed();

  //_maxBatchSize = 20, monitorSize=100, monitorInterval = 1 block,
  await deployProxy(LimitOrderMonitor,
      [limitOrderManagerInstance.address, uniswapFactory, kromatikaInstance.address, accounts[0],
        20, 100, 1],
      {deployer});

  const limitOrderMonitorInstance = await LimitOrderMonitor.deployed()
  await limitOrderManagerInstance.addMonitor(limitOrderMonitorInstance.address);
};
