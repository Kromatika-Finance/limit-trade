const LimitTradeManager = artifacts.require("LimitTradeManager");
const ERC20 = artifacts.require("ERC20");

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

        // kovan addresses
        // const token0 = "0x4F96Fe3b7A6Cf9725f59d353F723c1bDb64CA6Aa"; // DAI
        // const token1 = "0x6Ba45c470776fF94568A5802015B8b25965c2CEC"; // XLN

        const token0Instance = await ERC20.at(token0);
        const token1Instance = await ERC20.at(token1);

        const token0Decimals = await token0Instance.decimals();
        const token1Decimals = await token1Instance.decimals();

        const amount0 = web3.utils.toWei("0.001").toString();
        const amount1 = 0;

        // //mainnet
        const fee = 3000;

        //kovan
        //const fee = 500;

        // // target price: 1 UNI = 25.377 DAI --> sell UNI for DAI MAINNET
        let targetSqrtPriceX96 = encodeSqrtRatioX96(
            JSBI.BigInt(25377),
            JSBI.BigInt(1000));

        // target price: 1 DAI = 100150 XLN --> sell UNI for DAI KOVAN
        // let targetSqrtPriceX96 = encodeSqrtRatioX96(
        //     JSBI.BigInt(100150),
        //     JSBI.BigInt(1));

        const tradeInstance = await LimitTradeManager.deployed();

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

        console.log("Token0 --> " + token0.toString());
        console.log("Token1 --> " + token1.toString());
        console.log("Amount0 --> " + amount0.toString());
        console.log("Amount1 --> " + amount1.toString());
        console.log("TargetSqrtPriceX96 --> " + targetSqrtPriceX96.toString());
        console.log("Fee --> " + fee.toString());

        const receipt = await tradeInstance.openLimitTrade(
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