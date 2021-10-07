const LimitTradeManager = artifacts.require("LimitTradeManager");
const IERC20 = artifacts.require("IERC20");

const JSBI = require('jsbi');

const MAX_SAFE_INTEGER = JSBI.BigInt(Number.MAX_SAFE_INTEGER);
const ZERO = JSBI.BigInt(0);
const ONE = JSBI.BigInt(1);
const TWO = JSBI.BigInt(2);

module.exports = async(callback) => {

    try {

        const accounts = await web3.eth.getAccounts();
        const currentAccount = accounts[0];
        var BN = web3.utils.BN;

        // mainet addresses
        const token0 = "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984"; //UNI
        const token1 = "0x6b175474e89094c44da98b954eedeac495271d0f"; // DAI

        const amount0 = web3.utils.toWei("0.1").toString();
        const amount1 = 0;
        const fee = 3000;

        // target price: 1 UNI = 26.5104 DAI --> sell UNI for DAI
        let targetSqrtPriceX96 = encodeSqrtRatioX96(
            JSBI.BigInt(265104),
            JSBI.BigInt(10000));

        const tradeInstance = await LimitTradeManager.deployed();

        const token0Instance = await IERC20.at(token0);
        const token1Instance = await IERC20.at(token1);

        if (amount0 > 0) {
            await token0Instance.approve(
                tradeInstance.address,
                amount0,
                {from: currentAccount}
                );
        }

        if (amount1 > 0) {
            await token1Instance.approve(
                tradeInstance.address,
                amount1,
                {from: currentAccount}
            );
        }

        const receipt = await tradeInstance.createLimitTrade(
            token0,
            token1,
            amount0,
            amount1,
            new BN(targetSqrtPriceX96.toString()),
            fee,
            {from: currentAccount}
        );
        console.log('receipt:', receipt);

    } catch (error) {
        console.log(error);
    }
    callback();


    function encodeSqrtRatioX96(amount1, amount0) {
        const numerator = JSBI.leftShift(JSBI.BigInt(amount1), JSBI.BigInt(192))
        const denominator = JSBI.BigInt(amount0)
        const ratioX192 = JSBI.divide(numerator, denominator)
        return sqrt(ratioX192)
    }

    function sqrt(value) {

        // rely on built in sqrt if possible
        if (JSBI.lessThan(value, MAX_SAFE_INTEGER)) {
            return JSBI.BigInt(Math.floor(Math.sqrt(JSBI.toNumber(value))))
        }

        let z;
        let x;
        z = value
        x = JSBI.add(JSBI.divide(value, TWO), ONE)
        while (JSBI.lessThan(x, z)) {
            z = x
            x = JSBI.divide(JSBI.add(JSBI.divide(value, x), x), TWO)
        }
        return z
    }

};