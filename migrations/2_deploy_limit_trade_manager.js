const LimitTradeManager = artifacts.require("LimitTradeManager");

module.exports = async function (deployer, network, accounts) {

  const wrappedETHAddress = process.env.WETH;
  const positionManager = process.env.UNISWAP_POSITION_MANAGER;
  const uniswapFactory = process.env.UNISWAP_FACTORY;

  const controller = accounts[0];
  const keeper = accounts[0];
  const limitMargin = 120;

  await deployer.deploy(LimitTradeManager,
      controller, keeper, limitMargin, positionManager, uniswapFactory, wrappedETHAddress);
};
