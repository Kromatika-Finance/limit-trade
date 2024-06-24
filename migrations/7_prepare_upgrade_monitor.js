
const LimitOrderMonitorChainlink = artifacts.require('LimitOrderMonitorChainlink');
const LimitOrderMonitorChainlinkV2 = artifacts.require('LimitOrderMonitorChainlinkV2');

const { prepareUpgrade } = require('@openzeppelin/truffle-upgrades');

module.exports = async function (deployer) {
    const box = await LimitOrderMonitorChainlink.deployed();
    await prepareUpgrade(box.address, LimitOrderMonitorChainlinkV2, {deployer, unsafeAllow: ['constructor']});
};