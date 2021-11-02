const LimitOrderManager = artifacts.require("LimitOrderManager");
const LimitOrderManagerChainlink = artifacts.require("LimitOrderManagerChainlink");
const LimitOrderMonitor = artifacts.require("LimitOrderMonitor");
const {deployProxy} = require("@openzeppelin/truffle-upgrades");

module.exports = async function (deployer, network, accounts) {

  const positionManager = process.env.UNISWAP_POSITION_MANAGER;
  const uniswapFactory = process.env.UNISWAP_FACTORY;

  const limitOrderManagerInstance = await LimitOrderManagerChainlink.deployed();

  //_maxBatchSize = 20, monitorSize=500, monitorInterval = 1 block, monitorFee = 10 %
  await deployProxy(LimitOrderMonitor,
      [limitOrderManagerInstance.address, positionManager, uniswapFactory,
        20, 500, 1, 10000],
      {deployer});

  const limitOrderMonitorInstance = await LimitOrderMonitor.deployed()
  await limitOrderManagerInstance.setMonitors([limitOrderMonitorInstance.address]);
};
