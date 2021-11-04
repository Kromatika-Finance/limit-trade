const LimitOrderManager = artifacts.require("LimitOrderManager");

module.exports = async(callback) => {

    try {

        const accounts = await web3.eth.getAccounts();
        const currentAccount = accounts[0];

        const tradeInstance = await LimitOrderManager.deployed();
        const tokenId = "4";

        //claim funds
        const receipt = await tradeInstance.collect(
            tokenId,
            {from: currentAccount}
        );
        console.log('receipt:', receipt);

    } catch (error) {
        console.log(error);
    }
    callback();

};