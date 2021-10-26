const LimitOrderManager = artifacts.require("LimitOrderManager");
const Kromatika = artifacts.require("Kromatika");
const {deployProxy} = require("@openzeppelin/truffle-upgrades");

module.exports = async function (deployer, network, accounts) {

  const wrappedETHAddress = process.env.WETH;
  const positionManager = process.env.UNISWAP_POSITION_MANAGER;
  const uniswapFactory = process.env.UNISWAP_FACTORY;
  const quoterV2 = process.env.UNISWAP_QUOTER;

  const kromatikaInstance = await Kromatika.deployed();

  // 200k gas cost
  await deployProxy(LimitOrderManager,
      [positionManager, uniswapFactory, wrappedETHAddress, kromatikaInstance.address, quoterV2, 200000],
      {deployer});
};
