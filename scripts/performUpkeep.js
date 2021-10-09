const LimitSignalKeeper = artifacts.require("LimitSignalKeeper");
const INonfungiblePositionManager = artifacts.require("INonfungiblePositionManager");
const IUniswapV3Factory = artifacts.require("IUniswapV3Factory");
const IUniswapV3Pool = artifacts.require("IUniswapV3Pool");

module.exports = async(callback) => {

    const positionManager = process.env.UNISWAP_POSITION_MANAGER;
    const uniswapFactory = process.env.UNISWAP_FACTORY;

    try {

        const accounts = await web3.eth.getAccounts();
        const currentAccount = accounts[0];

        const limitSignalInstance = await LimitSignalKeeper.deployed();

        const tokenId = 138089;

        const deposit = await limitSignalInstance.depositPerTokenId(tokenId);
        console.log('deposit:', JSON.stringify(deposit));

        const positionManagerInstance = await INonfungiblePositionManager.at(positionManager);
        const position = await positionManagerInstance.positions(tokenId);

        const uniswapFactoryInstance = await IUniswapV3Factory.at(uniswapFactory);
        const poolAddress = await uniswapFactoryInstance.getPool(position.token0, position.token1, position.fee);

        const result = await limitSignalInstance._amountsForLiquidity(
            poolAddress, position.tickLower, position.tickUpper, position.liquidity
            );
        console.log('result:', JSON.stringify(result));

        const receipt = await limitSignalInstance.checkUpkeep.call('0x');
        console.log('receipt:', receipt);
        if (receipt.upkeepNeeded) {
            const performUpkeep = await limitSignalInstance.performUpkeep(receipt.performData);
            console.log('performUpkeep:', performUpkeep);
        }

    } catch (error) {
        console.log(error);
    }
    callback();
}