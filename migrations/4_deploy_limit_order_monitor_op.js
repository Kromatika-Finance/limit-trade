const LimitOrderManager = artifacts.require("OpLimitOrderManager");
const LimitOrderMonitor = artifacts.require("LimitOrderMonitor");
const Kromatika = artifacts.require("Kromatika");
const {deployProxy} = require("@openzeppelin/truffle-upgrades");

module.exports = async function (deployer, network, accounts) {

  const uniswapFactory = process.env.UNISWAP_FACTORY;

  const limitOrderManagerInstance = await LimitOrderManager.deployed();
  const kromatikaInstance = await Kromatika.deployed();

  //_maxBatchSize = 10, monitorSize=20, monitorInterval = 1 block,
  // monitorFee = 20 % (this needs to be in a global config); the same % should be applied in the estimation
  await deployProxy(LimitOrderMonitor,
      [limitOrderManagerInstance.address, uniswapFactory, kromatikaInstance.address, accounts[0],
        20, 100, 1],
      {deployer});

  const limitOrderMonitorInstance = await LimitOrderMonitor.deployed()
  await limitOrderManagerInstance.addMonitor(limitOrderMonitorInstance.address);
};
