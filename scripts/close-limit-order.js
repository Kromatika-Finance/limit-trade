const LimitTradeManager = artifacts.require("LimitTradeManager");
const IERC20 = artifacts.require("IERC20");

module.exports = async(callback) => {

    try {

        const accounts = await web3.eth.getAccounts();
        const currentAccount = accounts[0];

        const tradeInstance = await LimitTradeManager.deployed();
        const depositId = await tradeInstance.depositIdsPerAddress(currentAccount, 0);
        const depositInfo = await tradeInstance.deposits(depositId);

        const tokenId = depositInfo.tokenId?.toString();
        console.log("Position TokenID: " + tokenId);

        const receipt = await tradeInstance.closeLimitTrade(
            tokenId,
            {from: currentAccount}
        );
        console.log('receipt:', receipt);

    } catch (error) {
        console.log(error);
    }
    callback();

};