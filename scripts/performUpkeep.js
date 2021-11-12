const LimitOrderMonitor = artifacts.require("LimitOrderMonitorChainlink");
const LimitOrderManager = artifacts.require("LimitOrderManager");

module.exports = async(callback) => {

    try {

        const accounts = await web3.eth.getAccounts();
        const currentAccount = accounts[0];

        const limitMonitor = await LimitOrderMonitor.deployed();
        const limitManager = await LimitOrderManager.deployed();

        const targetGasPrice = web3.utils.toWei("20", "gwei");

        const isUnderfunded = await limitManager.isUnderfunded(currentAccount);
        console.log(JSON.stringify(isUnderfunded));

        const receipt = await limitMonitor.checkUpkeep.call('0x', {gasPrice: targetGasPrice});
        console.log('receipt:', receipt.upkeepNeeded);
        // if (receipt.upkeepNeeded) {
        //     const performUpkeep = await limitMonitor.performUpkeep(receipt.performData, {gasPrice: targetGasPrice});
        //     console.log('performUpkeep:', performUpkeep);
        // }

    } catch (error) {
        console.log(error);
    }
    callback();
}