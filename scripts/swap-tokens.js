const ISwapRouter = artifacts.require("ISwapRouter");
const IERC20 = artifacts.require("IERC20");

module.exports = async(callback) => {

    // swap from DAI to UNI
    const token0 = "0x6b175474e89094c44da98b954eedeac495271d0f"; //DAI
    const token1 = "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984"; // UNI

    const amount0 = web3.utils.toWei("15000").toString();

    const fee = "3000";
    const routerAddress = "0xE592427A0AEce92De3Edee1F18E0157C05861564";

    try {

        const accounts = await web3.eth.getAccounts();
        const currentAccount = accounts[0];

        const uniswapRouter = await ISwapRouter.at(routerAddress);
        const token0Instance = await IERC20.at(token0);
        const token1Instance = await IERC20.at(token1);

        if (amount0 > 0) {
            await token0Instance.approve(
                uniswapRouter.address,
                amount0,
                {from: currentAccount}
            );
        }

        const params = {
            tokenIn: token0,
            tokenOut: token1,
            fee: fee,
            recipient: currentAccount,
            deadline: Math.floor(Date.now() / 1000) + 900,
            amountIn: amount0,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0,
        };

        const receipt = await uniswapRouter.exactInputSingle(params, {from: currentAccount});
        console.log('receipt:', receipt);

        const balanceToken1 = await token1Instance.balanceOf(currentAccount);
        console.log('balanceToken1:', web3.utils.fromWei(balanceToken1));

    } catch (error) {
        console.log(error);
    }
    callback();
}