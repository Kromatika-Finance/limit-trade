
const LimitOrderManager = artifacts.require('LimitOrderManager');
const LimitOrderManagerV2 = artifacts.require('LimitOrderManagerV2');

const { prepareUpgrade } = require('@openzeppelin/truffle-upgrades');

module.exports = async function (deployer) {
    const box = await LimitOrderManager.deployed();
    await prepareUpgrade(box.address, LimitOrderManagerV2, {deployer, unsafeAllow: ['delegatecall', 'constructor']});
};