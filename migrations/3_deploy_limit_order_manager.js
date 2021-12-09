const LimitOrderManager = artifacts.require("LimitOrderManager");
const Kromatika = artifacts.require("Kromatika");
const UniswapUtils = artifacts.require("UniswapUtils");
const {deployProxy} = require("@openzeppelin/truffle-upgrades");

module.exports = async function (deployer, network, accounts) {

  const wrappedETHAddress = process.env.WETH;
  const uniswapFactory = process.env.UNISWAP_FACTORY;
  const feeAddress = process.env.FEE_ADDRESS;

  const kromatikaInstance = await Kromatika.deployed();

  await deployer.deploy(UniswapUtils);
  await deployer.link(UniswapUtils, LimitOrderManager);

  // 600k gas usage, 300 sec TWAP, 10% protocol fee
  await deployProxy(LimitOrderManager,
      [uniswapFactory, wrappedETHAddress, kromatikaInstance.address, feeAddress, 2000000, 10, 10000],
      {deployer, unsafeAllow: ["external-library-linking", 'delegatecall']});
};
