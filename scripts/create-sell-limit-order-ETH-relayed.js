const LimitOrderManager = artifacts.require("LimitOrderManager");
const ERC20 = artifacts.require("ERC20");
const Kromatika = artifacts.require("Kromatika");

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
        //let token1 = "0x7fc66500c84a76ad7e9c93437bfc5ac33e2ddae9"; // DAI

        // kovan addresses
        // const token0 = "0x4F96Fe3b7A6Cf9725f59d353F723c1bDb64CA6Aa"; // DAI
        let token1 = "0xa2A3D56fe58B0C42ED421CeC3355AC40184775c9"; // KROM on Ar

        let token0Instance = await ERC20.at(token0);
        let token1Instance = await ERC20.at(token1);
        let token0Decimals = await token0Instance.decimals();
        let token1Decimals = await token1Instance.decimals();

        let amount0 = new BN((0.0001 * 10 ** token0Decimals).toString());
        let amount1 = new BN((0 * 10 ** token1Decimals).toString());
        const margin = new BN(5);

        const fee = 3000;

        // // target price: 1 ETH = 3800 DAI --> sell ETH for DAI MAINNET
        let sellTokenPrice = "97000"; // token1 price of token0

        let targetGasPrice = web3.utils.toWei("10000", "wei");

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

        const tradeInstance = await LimitOrderManager.deployed();

        [token0, token1, amount0, amount1, sellTokenPrice] = sortTokens(token0, token1, amount0, amount1, sellTokenPrice);

        let msgValue = 0;
        if (token0 == process.env.WETH && amount0 > 0) {
            msgValue = amount0.add(new BN(msgValue.toString()))
        }
        if (token1 == process.env.WETH && amount1 > 0) {
            msgValue = amount1.add(new BN(msgValue.toString()))
        }

        console.log("Token0 --> " + token0.toString());
        console.log("Token1 --> " + token1.toString());
        console.log("Fee --> " + fee.toString());
        console.log("TargetSqrtPriceX96 --> " + targetSqrtPriceX96.toString());
        console.log("Amount0 --> " + amount0.toString());
        console.log("Amount1 --> " + amount1.toString());

        targetSqrtPriceX96 = new BN(targetSqrtPriceX96.toString());

        // sign the message

        const hashKey = web3.utils.soliditySha3(
                {t: 'address', v: token0},
                {t: 'address', v: token1},
                {t: 'uint24', v: fee},
                {t: 'uint160', v: targetSqrtPriceX96},
                {t: 'uint128', v: amount0},
                {t: 'uint128', v: amount1},
                {t: 'address', v: currentAccount}
            );

        let signature = await web3.eth.sign(hashKey, currentAccount);
        // signature = signature.substr(0, 130) + (signature.substr(130) == "00" ? "1b" : "1c"); // v: 0,1 => 27,28

        console.log('HASH:' + hashKey);
        console.log("SIG:" + signature);

        // encode function call
        const calldata = web3.eth.abi.encodeFunctionCall(
            {
                "inputs": [
                    {
                        "components": [
                            {
                                "internalType": "address",
                                "name": "_token0",
                                "type": "address"
                            },
                            {
                                "internalType": "address",
                                "name": "_token1",
                                "type": "address"
                            },
                            {
                                "internalType": "uint24",
                                "name": "_fee",
                                "type": "uint24"
                            },
                            {
                                "internalType": "uint160",
                                "name": "_sqrtPriceX96",
                                "type": "uint160"
                            },
                            {
                                "internalType": "uint128",
                                "name": "_amount0",
                                "type": "uint128"
                            },
                            {
                                "internalType": "uint128",
                                "name": "_amount1",
                                "type": "uint128"
                            },
                            {
                                "internalType": "bool",
                                "name": "native",
                                "type": "bool"
                            }
                        ],
                        "internalType": "struct IOrderManager.LimitOrderParams",
                        "name": "params",
                        "type": "tuple"
                    },
                    {
                        "internalType": "address",
                        "name": "_owner",
                        "type": "address"
                    },
                    {
                        "internalType": "bytes",
                        "name": "signature",
                        "type": "bytes"
                    }
                ],
                "name": "placeLimitOrderRelayed",
                "outputs": [
                    {
                        "internalType": "uint256",
                        "name": "_tokenId",
                        "type": "uint256"
                    }
                ],
                "stateMutability": "payable",
                "type": "function",
                "payable": true
            }
        , [[token0, token1, fee, targetSqrtPriceX96.toString(), amount0.toString(), amount1.toString(), false], currentAccount, signature])

        const calldatas = [];
        calldatas.push(calldata);

        console.log('CALLDATA: ' + calldata);
        console.log(msgValue.toString());

        const receipt = await tradeInstance.multicall(calldatas, {from: currentAccount});
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