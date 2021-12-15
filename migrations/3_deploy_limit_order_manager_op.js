const LimitOrderManager = artifacts.require("OpLimitOrderManager");
const Kromatika = artifacts.require("Kromatika");
const LimitManagerUtils = artifacts.require("ManagerUtils");
const OpAccessToken = artifacts.require("OpAccessToken");
const {deployProxy} = require("@openzeppelin/truffle-upgrades");

module.exports = async function (deployer, network, accounts) {

  const wrappedETHAddress = process.env.WETH;
  const uniswapFactory = process.env.UNISWAP_FACTORY;
  const uniswapQuoter = process.env.UNISWAP_QUOTER;
  const feeAddress = process.env.FEE_ADDRESS;

  const kromatikaInstance = await Kromatika.deployed();

  await deployProxy(LimitManagerUtils, [], {deployer});
  const managerUtilsInstance = await LimitManagerUtils.deployed();

  await deployProxy(OpAccessToken, [], {deployer, unsafeAllow: ["external-library-linking", 'delegatecall', 'state-variable-immutable', 'state-variable-assignment']})
  const accessTokenInstance = await OpAccessToken.deployed();

  // 600k gas usage, 10% protocol fee ; 50% discount
  await deployProxy(LimitOrderManager,
      [uniswapFactory, uniswapQuoter, wrappedETHAddress, managerUtilsInstance.address, kromatikaInstance.address, accessTokenInstance.address,
        feeAddress, 600000, 10000, 50000],
      {deployer, unsafeAllow: ['delegatecall']});

  await accessTokenInstance.mint(accounts[0]);
};
