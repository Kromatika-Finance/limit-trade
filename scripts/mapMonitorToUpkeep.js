const LimitOrderMonitor = artifacts.require("LimitOrderMonitorChainlink");

module.exports = async(callback) => {


    try {

        const accounts = await web3.eth.getAccounts();
        const currentAccount = accounts[0];

        const limitMonitor = await LimitOrderMonitor.deployed();

        const receipt = await limitMonitor.setKeeperId(1217);
        console.log('receipt:', receipt);

        // let targetGasPrice = web3.utils.toWei("50", "gwei");
        // const _data = web3.eth.abi.encodeParameters(['uint256'],
        //     [targetGasPrice]);
        // console.log(_data)

    } catch (error) {
        console.log(error);
    }
    callback();
}