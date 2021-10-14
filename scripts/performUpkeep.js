const LimitTradeMonitor = artifacts.require("LimitTradeMonitor");

module.exports = async(callback) => {

    const positionManager = process.env.UNISWAP_POSITION_MANAGER;
    const uniswapFactory = process.env.UNISWAP_FACTORY;

    try {

        const accounts = await web3.eth.getAccounts();
        const currentAccount = accounts[0];

        const limitMonitor = await LimitTradeMonitor.deployed();

        const receipt = await limitMonitor.checkUpkeep.call('0x');
        console.log('receipt:', receipt.upkeepNeeded);
        if (receipt.upkeepNeeded) {
            const performUpkeep = await limitMonitor.performUpkeep(receipt.performData);
            console.log('performUpkeep:', performUpkeep);
        }

    } catch (error) {
        console.log(error);
    }
    callback();
}