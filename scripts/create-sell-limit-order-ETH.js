const LimitOrderManager = artifacts.require("LimitOrderManager");
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
        let token0 = process.env.WETH;
        let token1 = "0x6b175474e89094c44da98b954eedeac495271d0f"; // DAI

        // kovan addresses
        // const token0 = "0x4F96Fe3b7A6Cf9725f59d353F723c1bDb64CA6Aa"; // DAI
        // const token1 = "0x6Ba45c470776fF94568A5802015B8b25965c2CEC"; // XLN

        let token0Instance = await ERC20.at(token0);
        let token1Instance = await ERC20.at(token1);
        let token0Decimals = await token0Instance.decimals();
        let token1Decimals = await token1Instance.decimals();

        let amount0 = new BN((0.001 * 10 ** token0Decimals).toString());
        let amount1 = new BN((0 * 10 ** token1Decimals).toString());
        const margin = new BN(5);

        // //mainnet
        const fee = 3000;

        //kovan
        //const fee = 500;

        // // target price: 1 ETH = 3800 DAI --> sell ETH for DAI MAINNET
        let sellTokenPrice = "3800"; // token1 price of token0

        // sort tokens
        [token0, token1, amount0, amount1, sellTokenPrice] = sortTokens(token0, token1, amount0, amount1, sellTokenPrice);
        token0Instance = await ERC20.at(token0);
        token1Instance = await ERC20.at(token1);
        token0Decimals = (await token0Instance.decimals()).add(margin);
        token1Decimals = (await token1Instance.decimals()).add(margin);
        // encode price
        console.log(sellTokenPrice);
        console.log(token1Decimals.toString());
        let targetSqrtPriceX96 = encodeSqrtRatioX96(
            JSBI.BigInt(sellTokenPrice * 10 ** token1Decimals),
            JSBI.BigInt(1 * 10 ** token0Decimals));

        // target price: 1 DAI = 100150 XLN --> sell UNI for DAI KOVAN
        // let targetSqrtPriceX96 = encodeSqrtRatioX96(
        //     JSBI.BigInt(100150),
        //     JSBI.BigInt(1));

        const tradeInstance = await LimitOrderManager.deployed();

        let value;
        let token;
        let amount;
        if (token0 == process.env.WETH) {
            value = amount0;
            token = token1;
            amount = amount1;
        } else {
            value = amount1;
            token = token0;
            amount = amount0;
        }

        console.log("Token1 --> " + token.toString());
        console.log("Amount0 --> " + value.toString());
        console.log("Amount1 --> " + amount.toString());
        console.log("TargetSqrtPriceX96 --> " + targetSqrtPriceX96.toString());
        console.log("Fee --> " + fee.toString());

        const receipt = await tradeInstance.openOrderETH(
            token,
            fee,
            new BN(targetSqrtPriceX96.toString()),
            amount,
            {value: value, from: currentAccount}
        );
        console.log('receipt:', receipt);

    } catch (error) {
        console.log(error);
    }
    callback();

    function sortTokens(token0, token1, amount0, amount1, tokenPrice) {
        if (token0 < token1) {
            return [token0, token1, amount0, amount1, tokenPrice];
        } else {
            // inverse
            return [token1, token0, amount1, amount0, 1/tokenPrice];
        }
    }

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