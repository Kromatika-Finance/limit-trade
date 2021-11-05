const LimitOrderManager = artifacts.require("LimitOrderManager");
const IUniswapV3Pool = artifacts.require("IUniswapV3Pool");

const JSBI = require('jsbi');

const Q32 = JSBI.exponentiate(JSBI.BigInt(2), JSBI.BigInt(32))
const Q96 = JSBI.exponentiate(JSBI.BigInt(2), JSBI.BigInt(96));
const Q192 = JSBI.exponentiate(Q96, JSBI.BigInt(2));
const ZERO = JSBI.BigInt(0);
const ONE = JSBI.BigInt(1);
const TWO = JSBI.BigInt(2);
const MaxUint256 = JSBI.BigInt('0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff')

module.exports = async(callback) => {

    try {

        const accounts = await web3.eth.getAccounts();
        const currentAccount = accounts[0];

        const tradeInstance = await LimitOrderManager.deployed();
        const tokenIdsCount = await tradeInstance.balanceOf(currentAccount);

        for (let i=0; i< tokenIdsCount; i++) {

            console.log("=================================================");
            const tokenId = await tradeInstance.tokenOfOwnerByIndex(currentAccount, i);
            const orderInfo = await tradeInstance.orders(tokenId);

            console.log("TokenID: " + tokenId);

            console.log(JSON.stringify(orderInfo));

            if (orderInfo.processed == 0) {
                // get token id info from univ3
                console.log("Position LowerLimit: " + decodeSqrtRatioX96(
                    getSqrtRatioAtTick(orderInfo.tickLower)).toString()
                );
                console.log("Position UpperLimit: " + decodeSqrtRatioX96(
                    getSqrtRatioAtTick(orderInfo.tickUpper)).toString()
                );

                console.log(JSON.stringify(orderInfo));

            }
        }

    } catch (error) {
        console.log(error);
    }
    callback();

    function getSqrtRatioAtTick(tick) {
        const absTick = tick < 0 ? tick * -1 : tick

        let ratio =
            (absTick & 0x1) != 0
                ? JSBI.BigInt('0xfffcb933bd6fad37aa2d162d1a594001')
                : JSBI.BigInt('0x100000000000000000000000000000000')
        if ((absTick & 0x2) != 0) ratio = mulShift(ratio, '0xfff97272373d413259a46990580e213a')
        if ((absTick & 0x4) != 0) ratio = mulShift(ratio, '0xfff2e50f5f656932ef12357cf3c7fdcc')
        if ((absTick & 0x8) != 0) ratio = mulShift(ratio, '0xffe5caca7e10e4e61c3624eaa0941cd0')
        if ((absTick & 0x10) != 0) ratio = mulShift(ratio, '0xffcb9843d60f6159c9db58835c926644')
        if ((absTick & 0x20) != 0) ratio = mulShift(ratio, '0xff973b41fa98c081472e6896dfb254c0')
        if ((absTick & 0x40) != 0) ratio = mulShift(ratio, '0xff2ea16466c96a3843ec78b326b52861')
        if ((absTick & 0x80) != 0) ratio = mulShift(ratio, '0xfe5dee046a99a2a811c461f1969c3053')
        if ((absTick & 0x100) != 0) ratio = mulShift(ratio, '0xfcbe86c7900a88aedcffc83b479aa3a4')
        if ((absTick & 0x200) != 0) ratio = mulShift(ratio, '0xf987a7253ac413176f2b074cf7815e54')
        if ((absTick & 0x400) != 0) ratio = mulShift(ratio, '0xf3392b0822b70005940c7a398e4b70f3')
        if ((absTick & 0x800) != 0) ratio = mulShift(ratio, '0xe7159475a2c29b7443b29c7fa6e889d9')
        if ((absTick & 0x1000) != 0) ratio = mulShift(ratio, '0xd097f3bdfd2022b8845ad8f792aa5825')
        if ((absTick & 0x2000) != 0) ratio = mulShift(ratio, '0xa9f746462d870fdf8a65dc1f90e061e5')
        if ((absTick & 0x4000) != 0) ratio = mulShift(ratio, '0x70d869a156d2a1b890bb3df62baf32f7')
        if ((absTick & 0x8000) != 0) ratio = mulShift(ratio, '0x31be135f97d08fd981231505542fcfa6')
        if ((absTick & 0x10000) != 0) ratio = mulShift(ratio, '0x9aa508b5b7a84e1c677de54f3e99bc9')
        if ((absTick & 0x20000) != 0) ratio = mulShift(ratio, '0x5d6af8dedb81196699c329225ee604')
        if ((absTick & 0x40000) != 0) ratio = mulShift(ratio, '0x2216e584f5fa1ea926041bedfe98')
        if ((absTick & 0x80000) != 0) ratio = mulShift(ratio, '0x48a170391f7dc42444e8fa2')

        if (tick > 0) ratio = JSBI.divide(MaxUint256, ratio)

        // back to Q96
        return JSBI.greaterThan(JSBI.remainder(ratio, Q32), ZERO)
            ? JSBI.add(JSBI.divide(ratio, Q32), ONE)
            : JSBI.divide(ratio, Q32)
    }

    function mulShift(val, mulBy) {
        return JSBI.signedRightShift(JSBI.multiply(val, JSBI.BigInt(mulBy)), JSBI.BigInt(128))
    }

    function decodeSqrtRatioX96(sqrtRatioX96) {
        const numerator = JSBI.multiply(sqrtRatioX96, sqrtRatioX96);
        const denominator = Q192;
        //const price  = JSBI.divide(numerator, denominator);
        return JSBI.toNumber(numerator) / JSBI.toNumber(denominator);
    }
};