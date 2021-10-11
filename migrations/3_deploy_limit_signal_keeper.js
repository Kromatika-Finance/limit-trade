const LimitTradeManager = artifacts.require("LimitTradeManager");
const LimitSignalKeeper = artifacts.require("LimitSignalKeeper");

module.exports = async function (deployer, network, accounts) {

  const positionManager = process.env.UNISWAP_POSITION_MANAGER;
  const uniswapFactory = process.env.UNISWAP_FACTORY;
  const fastGasFeed = process.env.CHAINLINK_GAS_FEED;

  const limitTradeManagerInstance = await LimitTradeManager.deployed();

  await deployer.deploy(LimitSignalKeeper,
      limitTradeManagerInstance.address, positionManager, uniswapFactory, fastGasFeed);

  const limitSignalKeeperInstance = await LimitSignalKeeper.deployed()
  await limitTradeManagerInstance.changeKeeper(limitSignalKeeperInstance.address);
};
