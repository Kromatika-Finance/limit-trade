const LimitOrderManager = artifacts.require("LimitOrderManager");
const {deployProxy} = require("@openzeppelin/truffle-upgrades");

module.exports = async function (deployer, network, accounts) {

  const wrappedETHAddress = process.env.WETH;
  const positionManager = process.env.UNISWAP_POSITION_MANAGER;
  const uniswapFactory = process.env.UNISWAP_FACTORY;

  await deployProxy(LimitOrderManager,
      [positionManager, uniswapFactory, wrappedETHAddress, accounts[0], 0],
      {deployer});
};