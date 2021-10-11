const LimitTradeManager = artifacts.require("LimitTradeManager");
const LimitSignalKeeper = artifacts.require("LimitSignalKeeper");

module.exports = async function (deployer, network, accounts) {

  const positionManager = process.env.UNISWAP_POSITION_MANAGER;
  const uniswapFactory = process.env.UNISWAP_FACTORY;

  const limitTradeManagerInstance = await LimitTradeManager.deployed();

  await deployer.deploy(LimitSignalKeeper,
      limitTradeManagerInstance.address, positionManager, uniswapFactory, 50, 1);

  const limitSignalKeeperInstance = await LimitSignalKeeper.deployed()
  await limitTradeManagerInstance.changeKeeper(limitSignalKeeperInstance.address);
};
