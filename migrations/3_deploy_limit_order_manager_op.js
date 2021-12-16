const LimitOrderManager = artifacts.require("OpLimitOrderManager");
const Kromatika = artifacts.require("Kromatika");
const LimitManagerUtils = artifacts.require("ManagerUtils");
const OpAccessToken = artifacts.require("OpAccessToken");
const WETHExtended = artifacts.require("WETHExtended");
const {deployProxy} = require("@openzeppelin/truffle-upgrades");

module.exports = async function (deployer, network, accounts) {

  const wrappedETHAddress = process.env.WETH;
  const uniswapFactory = process.env.UNISWAP_FACTORY;
  const uniswapQuoter = process.env.UNISWAP_QUOTER;
  const feeAddress = process.env.FEE_ADDRESS;

  const kromatikaInstance = await Kromatika.deployed();

  await deployProxy(LimitManagerUtils, [], {deployer});
  await deployer.deploy(WETHExtended);

  const managerUtilsInstance = await LimitManagerUtils.deployed();
  const WETHExtendedInstance = await WETHExtended.deployed();

  await deployProxy(OpAccessToken, [], {deployer, unsafeAllow: ["external-library-linking", 'delegatecall', 'state-variable-immutable', 'state-variable-assignment']})
  const accessTokenInstance = await OpAccessToken.deployed();

  // 600k gas usage, 10% protocol fee ; 50% discount
  await deployProxy(LimitOrderManager,
      [uniswapFactory, uniswapQuoter, wrappedETHAddress, WETHExtendedInstance.address,
          managerUtilsInstance.address, kromatikaInstance.address, accessTokenInstance.address,
        feeAddress, 1200000000, 10000, 50000],
      {deployer, unsafeAllow: ['delegatecall']});

  await accessTokenInstance.mint(accounts[0]);
};
