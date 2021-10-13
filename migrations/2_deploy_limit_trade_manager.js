const LimitTradeManager = artifacts.require("LimitTradeManager");

module.exports = async function (deployer, network, accounts) {

  const wrappedETHAddress = process.env.WETH;
  const positionManager = process.env.UNISWAP_POSITION_MANAGER;
  const uniswapFactory = process.env.UNISWAP_FACTORY;

  await deployer.deploy(LimitTradeManager,positionManager, uniswapFactory, wrappedETHAddress);
};
