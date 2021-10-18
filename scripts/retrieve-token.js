const LimitOrderManager = artifacts.require("LimitOrderManager");
const INonfungiblePositionManager = artifacts.require("INonfungiblePositionManager");

module.exports = async(callback) => {

    const positionManager = process.env.UNISWAP_POSITION_MANAGER;

    try {

        const accounts = await web3.eth.getAccounts();
        const currentAccount = accounts[0];

        const tokenId = 141202;

        const tradeInstance = await LimitOrderManager.deployed();
        const receipt = await tradeInstance.retrieveToken(
            tokenId,
            {from: currentAccount}
        );
        console.log('receipt:', receipt);

        // decrease liqudiity

        const positionManagerInstance = await INonfungiblePositionManager.at(positionManager);
        const position = await positionManagerInstance.positions(tokenId);

        console.log(position.liquidity.toString());
        console.log(Math.trunc(Date.now() / 1000) + (1 * 60));

        const receipt2 = await positionManagerInstance.decreaseLiquidity({
            tokenId: tokenId,
            liquidity: position.liquidity.toString(),
            amount0Min: 0,
            amount1Min: 0,
            deadline: Math.trunc(Date.now() / 1000) + (1 * 60),
        }, {from: currentAccount});

        console.log('receipt2:', receipt2);

    } catch (error) {
        console.log(error);
    }
    callback();

};