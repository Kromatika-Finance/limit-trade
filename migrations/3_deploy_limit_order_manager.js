const LimitOrderManager = artifacts.require("LimitOrderManager");
const LimitOrderManagerChainlink = artifacts.require("LimitOrderManagerChainlink");
const Kromatika = artifacts.require("Kromatika");
const {deployProxy} = require("@openzeppelin/truffle-upgrades");

module.exports = async function (deployer, network, accounts) {

  const wrappedETHAddress = process.env.WETH;
  const positionManager = process.env.UNISWAP_POSITION_MANAGER;
  const uniswapFactory = process.env.UNISWAP_FACTORY;
  const router = process.env.UNISWAP_ROUTER;

  const linkAddress = process.env.LINK;

  const kromatikaInstance = await Kromatika.deployed();

  // // 200k gas cost
  // await deployProxy(LimitOrderManager,
  //     [positionManager, uniswapFactory, wrappedETHAddress, kromatikaInstance.address, 200000],
  //     {deployer});

  await deployProxy(LimitOrderManagerChainlink,
      [positionManager, uniswapFactory, wrappedETHAddress, kromatikaInstance.address, 500000, router, linkAddress],
      {deployer});
};
