const LimitOrderManager = artifacts.require("LimitOrderManager");
const IERC721 = artifacts.require("IERC721");

module.exports = async(callback) => {

    const positionManager = process.env.UNISWAP_POSITION_MANAGER;

    try {

        const accounts = await web3.eth.getAccounts();
        const currentAccount = accounts[0];

        const tradeInstance = await LimitOrderManager.deployed();
        const tokenInstance = await IERC721.at(positionManager);

        const tokenId = "140788";

        const receipt = await tokenInstance.safeTransferFrom(
            currentAccount,
            tradeInstance.address,
            tokenId,
            {from: currentAccount}
        );
        console.log('receipt:', receipt);

    } catch (error) {
        console.log(error);
    }
    callback();

};