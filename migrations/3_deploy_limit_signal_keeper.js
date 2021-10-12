const LimitTradeManager = artifacts.require("LimitTradeManager");
const LimitSignalKeeper = artifacts.require("LimitSignalKeeper");

module.exports = async function (deployer, network, accounts) {

  const positionManager = process.env.UNISWAP_POSITION_MANAGER;
  const uniswapFactory = process.env.UNISWAP_FACTORY;

  const limitTradeManagerInstance = await LimitTradeManager.deployed();


  //_maxBatchSize = 50 _upkeepInterval = 1, _keeperFee = 10 %
  await deployer.deploy(LimitSignalKeeper,
      limitTradeManagerInstance.address, positionManager, uniswapFactory, 50, 1, 10000);

  const limitSignalKeeperInstance = await LimitSignalKeeper.deployed()
  await limitTradeManagerInstance.changeKeeper(limitSignalKeeperInstance.address);
};
