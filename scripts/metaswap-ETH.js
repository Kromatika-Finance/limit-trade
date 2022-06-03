const KromatikaMetaSwap = artifacts.require("KromatikaMetaSwap");
const ERC20 = artifacts.require("ERC20");

module.exports = async(callback) => {

    try {

        const accounts = await web3.eth.getAccounts();
        const currentAccount = accounts[0];

        const metaSwap = await KromatikaMetaSwap.deployed();

        const tokenFrom = "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE"; //eth
        const tokenTo = "0x14af1f2f02dccb1e43402339099a05a5e363b83c"; // KROM

        const amountFrom = "100000000000000000";

        const aggregatorAddress = "0x1111111254fb6c44bac0bed2854e76f90643097d"; // 1inch
        const aggregatorData = "0xe449022e000000000000000000000000000000000000000000000000016345785d8a00000000000000000000000000000000000000000000000000000f24fbab4f64ae7e00000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000001400000000000000000000000ba589ba3af52975a12acc6de69c9ab3ac1ae7804cfee7c08";
        // at block 14813128

        let token0Instance = await ERC20.at(tokenTo);
        let balanceToken0Before = await token0Instance.balanceOf(currentAccount);
        console.log('balanceToken0Before:', web3.utils.fromWei(balanceToken0Before.toString()));

        let balanceETHBefore = await web3.eth.getBalance(currentAccount)
        console.log('ETH balance before:', web3.utils.fromWei(balanceETHBefore.toString()));

        const adapterId = web3.utils.asciiToHex('SwapAggregator');
        console.log(adapterId)
        const adapterData = web3.eth.abi.encodeParameter(
            'tuple(address,address,uint256,address,bytes)',
            [tokenFrom, tokenTo, amountFrom, aggregatorAddress, aggregatorData]
        );

        console.log(adapterData);
        // const estimatedGas = await metaSwap.swap.estimateGas(tokenFrom, amountFrom,
        //     [
        //         adapterId,
        //         adapterData
        //     ]
        // ,{value: amountFrom, from: currentAccount});
        //
        // const gasLimit = new web3.utils.BN(estimatedGas * 1.10);
        //
        // const performedSwap = await metaSwap.swap(tokenFrom, amountFrom,
        //     [
        //         adapterId,
        //         adapterData
        //     ]
        //     ,{value: amountFrom, from: currentAccount, gas: gasLimit});
        //
        // console.log('performedSwap:', performedSwap);
        //
        // const balanceToken0After = await token0Instance.balanceOf(currentAccount);
        // console.log('balanceToken0 after:', web3.utils.fromWei(balanceToken0After.toString()));
        //
        // const balanceETHAfter = await web3.eth.getBalance(currentAccount)
        // console.log('ETH balance after:', web3.utils.fromWei(balanceETHAfter.toString()));
        //
        // console.log("Token diff: " + web3.utils.fromWei((balanceToken0After - balanceToken0Before).toString()));
        // console.log("ETH diff: " + web3.utils.fromWei((balanceETHAfter - balanceETHBefore).toString()));

    } catch (error) {
        console.log(error);
    }
    callback();
}