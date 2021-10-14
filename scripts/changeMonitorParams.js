const LimitOrderMonitor = artifacts.require("LimitOrderMonitor");

module.exports = async(callback) => {


    try {

        const accounts = await web3.eth.getAccounts();
        const currentAccount = accounts[0];

        const limitSignalInstance = await LimitOrderMonitor.deployed();

        const receipt = await limitSignalInstance.setBatchSize(30);
        console.log('receipt:', receipt);

    } catch (error) {
        console.log(error);
    }
    callback();
}