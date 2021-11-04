const LimitOrderManager = artifacts.require("LimitOrderManager");
const IERC20 = artifacts.require("IERC20");

module.exports = async(callback) => {

    try {

        const accounts = await web3.eth.getAccounts();
        const currentAccount = accounts[0];

        const tradeInstance = await LimitOrderManager.deployed();

        const tokenId = "3";

        const receipt = await tradeInstance.cancelLimitOrder(
            tokenId,
            {from: currentAccount}
        );
        console.log('receipt:', receipt);

    } catch (error) {
        console.log(error);
    }
    callback();

};