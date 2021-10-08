const LimitTradeManager = artifacts.require("LimitTradeManager");
const IERC20 = artifacts.require("IERC20");

module.exports = async(callback) => {

    try {

        const accounts = await web3.eth.getAccounts();
        const currentAccount = accounts[0];

        const tradeInstance = await LimitTradeManager.deployed();
        const depositId = await tradeInstance.depositIdsPerAddress(currentAccount, 0);

        // claim funds
        const receipt = await tradeInstance.claimLimitTrade(
            depositId,
            1,
            '0x',
            {from: currentAccount}
        );
        console.log('receipt:', receipt);

    } catch (error) {
        console.log(error);
    }
    callback();

};