const LimitTradeManager = artifacts.require("LimitTradeManager");
const LimitTradeMonitor = artifacts.require("LimitTradeMonitor");
const {deployProxy} = require("@openzeppelin/truffle-upgrades");

module.exports = async function (deployer, network, accounts) {

  const positionManager = process.env.UNISWAP_POSITION_MANAGER;
  const uniswapFactory = process.env.UNISWAP_FACTORY;

  const limitTradeManagerInstance = await LimitTradeManager.deployed();

  //_maxBatchSize = 20, monitorSize=500, _upkeepInterval = 1, _keeperFee = 10 %
  await deployProxy(LimitTradeMonitor,
      [limitTradeManagerInstance.address, positionManager, uniswapFactory, 20, 500, 1, 10000],
      {deployer});

  const limitTradeMonitorInstance = await LimitTradeMonitor.deployed()
  await limitTradeManagerInstance.setMonitors([limitTradeMonitorInstance.address]);
};
