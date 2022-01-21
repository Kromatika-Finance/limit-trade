// migrations/4_prepare_upgrade_boxv2.js
const OpLimitOrderManager = artifacts.require('OpLimitOrderManager');
const OpLimitOrderManagerV2 = artifacts.require('OpLimitOrderManagerV2');

const { prepareUpgrade } = require('@openzeppelin/truffle-upgrades');

module.exports = async function (deployer) {
    const box = await OpLimitOrderManager.deployed();
    await prepareUpgrade(box.address, OpLimitOrderManagerV2, {deployer, unsafeAllow: ['delegatecall']});
};