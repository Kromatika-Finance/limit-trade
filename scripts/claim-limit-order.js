const LimitTradeManager = artifacts.require("LimitTradeManager");
const IERC20 = artifacts.require("IERC20");
const LimitTradeMonitor = artifacts.require("LimitTradeMonitor");

module.exports = async(callback) => {

    try {

        const accounts = await web3.eth.getAccounts();
        const currentAccount = accounts[0];

        const tradeInstance = await LimitTradeManager.deployed();
        const tokenId = "140647";

        const depositInfo = await tradeInstance.deposits(tokenId);
        console.log(JSON.stringify(depositInfo));

        const limitMonitor = await LimitTradeMonitor.deployed();
        const batchPayment = await limitMonitor.batchInfo(depositInfo.batchId);

        console.log(JSON.stringify(batchPayment));

        //claim funds
        const receipt = await tradeInstance.claimLimitTrade(
            tokenId,
            {value: batchPayment.payment, from: currentAccount}
        );
        console.log('receipt:', receipt);

    } catch (error) {
        console.log(error);
    }
    callback();

};