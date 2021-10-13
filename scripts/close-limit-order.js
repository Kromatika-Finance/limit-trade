const LimitTradeManager = artifacts.require("LimitTradeManager");
const IERC20 = artifacts.require("IERC20");

module.exports = async(callback) => {

    try {

        const accounts = await web3.eth.getAccounts();
        const currentAccount = accounts[0];

        const tradeInstance = await LimitTradeManager.deployed();

        const tokenId = "140377";

        const receipt = await tradeInstance.fastCloseLimitTrade(
            tokenId,
            {from: currentAccount}
        );
        console.log('receipt:', receipt);

    } catch (error) {
        console.log(error);
    }
    callback();

};