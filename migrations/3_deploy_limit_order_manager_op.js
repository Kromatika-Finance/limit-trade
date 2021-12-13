const LimitOrderManager = artifacts.require("OpLimitOrderManager");
const Kromatika = artifacts.require("Kromatika");
const UniswapUtils = artifacts.require("UniswapUtils");
const WETHExtended = artifacts.require("WETHExtended");
const OpAccessToken = artifacts.require("OpAccessToken");
const {deployProxy} = require("@openzeppelin/truffle-upgrades");

module.exports = async function (deployer, network, accounts) {

  const wrappedETHAddress = process.env.WETH;
  const uniswapFactory = process.env.UNISWAP_FACTORY;
  const feeAddress = process.env.FEE_ADDRESS;

  const kromatikaInstance = await Kromatika.deployed();

  await deployer.deploy(WETHExtended);
  await deployer.deploy(UniswapUtils);
  await deployer.link(UniswapUtils, LimitOrderManager);

  const WETHExtendedInstance = await WETHExtended.deployed();

  await deployProxy(OpAccessToken, [], {deployer, unsafeAllow: ["external-library-linking", 'delegatecall', 'state-variable-immutable', 'state-variable-assignment']})
  const accessTokenInstance = await OpAccessToken.deployed();

  // 600k gas usage, 300 sec TWAP, 10% protocol fee ; 50% discount
  await deployProxy(LimitOrderManager,
      [uniswapFactory, wrappedETHAddress, WETHExtendedInstance.address, kromatikaInstance.address, accessTokenInstance.address,
        feeAddress, 2000000, 10000, 50000],
      {deployer, unsafeAllow: ["external-library-linking", 'delegatecall', 'state-variable-immutable', 'state-variable-assignment']});

  await accessTokenInstance.mint(accounts[0]);
};
