const LimitTradeManager = artifacts.require("LimitTradeManager");
const LimitTradeMonitor = artifacts.require("LimitTradeMonitor");

module.exports = async function (deployer, network, accounts) {

  const positionManager = process.env.UNISWAP_POSITION_MANAGER;
  const uniswapFactory = process.env.UNISWAP_FACTORY;

  const limitTradeManagerInstance = await LimitTradeManager.deployed();


  //_maxBatchSize = 50 _upkeepInterval = 1, _keeperFee = 10 %
  await deployer.deploy(LimitTradeMonitor,
      limitTradeManagerInstance.address, positionManager, uniswapFactory, 50, 500, 1, 10000);

  const limitTradeMonitorInstance = await LimitTradeMonitor.deployed()
  await limitTradeManagerInstance.addMonitor(limitTradeMonitorInstance.address);
};
