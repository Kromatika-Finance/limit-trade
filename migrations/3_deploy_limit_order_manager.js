const LimitOrderManager = artifacts.require("LimitOrderManager");
const Kromatika = artifacts.require("Kromatika");
const UniswapUtils = artifacts.require("UniswapUtils");
const {deployProxy} = require("@openzeppelin/truffle-upgrades");

module.exports = async function (deployer, network, accounts) {

  const wrappedETHAddress = process.env.WETH;
  const uniswapFactory = process.env.UNISWAP_FACTORY;

  const kromatikaInstance = await Kromatika.deployed();

  await deployer.deploy(UniswapUtils);
  await deployer.link(UniswapUtils, LimitOrderManager);

  // 400k gas cost
  await deployProxy(LimitOrderManager,
      [uniswapFactory, wrappedETHAddress, kromatikaInstance.address, 800000],
      {deployer, unsafeAllow: ["external-library-linking"]});
};
