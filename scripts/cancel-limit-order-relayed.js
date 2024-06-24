const LimitOrderManager = artifacts.require("LimitOrderManager");
const IERC20 = artifacts.require("IERC20");

module.exports = async(callback) => {

    try {

        const accounts = await web3.eth.getAccounts();
        const currentAccount = accounts[0];

        const tradeInstance = await LimitOrderManager.deployed();

        const tokenId = "2";

        const nonce = await web3.eth.getTransactionCount(currentAccount, 'pending');
        const hashKey = web3.utils.soliditySha3(
            {t: 'uint256', v: tokenId},
            {t: 'address', v: currentAccount}
        );

        let signature = await web3.eth.sign(hashKey, currentAccount);

        const receipt = await tradeInstance.cancelLimitOrderRelayed(
            tokenId,
            currentAccount,
            signature,
            {from: currentAccount}
        );
        console.log('receipt:', receipt);

    } catch (error) {
        console.log(error);
    }
    callback();

};