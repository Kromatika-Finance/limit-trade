
const UniswapUtils = artifacts.require('UniswapUtils');
const UniswapUtilsV2 = artifacts.require('UniswapUtilsV2');

const { prepareUpgrade } = require('@openzeppelin/truffle-upgrades');

module.exports = async function (deployer) {
    const box = await UniswapUtils.deployed();
    await prepareUpgrade(box.address, UniswapUtilsV2, {deployer, unsafeAllow: ['constructor']});
};