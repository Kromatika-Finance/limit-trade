const KromatikaMetaSwap = artifacts.require("KromatikaMetaSwap");
const ERC20 = artifacts.require("ERC20");

module.exports = async(callback) => {

    try {

        const accounts = await web3.eth.getAccounts();
        const currentAccount = accounts[0];

        const metaSwap = await KromatikaMetaSwap.deployed();

        const tokenFrom = "0x3af33bef05c2dcb3c7288b77fe1c8d2aeba4d789"; //KROM
        const tokenTo = "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE"; // eth

        const amountFrom = "380000000000000000000";
        let token0Instance = await ERC20.at(tokenFrom);

        if (amountFrom > 0) {
            await token0Instance.approve(
                metaSwap.address,
                amountFrom,
                {from: currentAccount, gas: 50000}
            );

            console.log('Allowance: ' + (await token0Instance.allowance(currentAccount, metaSwap.address)).toString());
        }

        let balanceToken0Before = await token0Instance.balanceOf(currentAccount);
        console.log('balanceToken0Before:', web3.utils.fromWei(balanceToken0Before.toString()));

        let balanceETHBefore = await web3.eth.getBalance(currentAccount)
        console.log('ETH balance before:', web3.utils.fromWei(balanceETHBefore.toString()));

        const aggregatorAddress = "0x1111111254fb6c44bac0bed2854e76f90643097d"; // 1inch
        const aggregatorData = "0xe449022e000000000000000000000000000000000000000000000014998f32ac78700000000000000000000000000000000000000000000000000000002188d92d38b441000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000012000000000000000000000006ae0cdc5d2b89a8dcb99ad6b3435b3e7f7290077cfee7c08";
        // at block 14813128

        const adapterId = 'SwapAggregator';
        const adapterData = web3.eth.abi.encodeParameter(
            'tuple(address,address,uint256,address,bytes)',
            [tokenFrom, tokenTo, amountFrom, aggregatorAddress, aggregatorData]
        );

        const estimatedGas = await metaSwap.swap.estimateGas(tokenFrom, amountFrom,
            [
                adapterId,
                adapterData
            ]
        ,{from: currentAccount});

        const performedSwap = await metaSwap.swap(tokenFrom, amountFrom,
            [
                adapterId,
                adapterData
            ]
            ,{from: currentAccount, gas: estimatedGas});

        console.log('performedSwap:', performedSwap);

        const balanceToken0After = await token0Instance.balanceOf(currentAccount);
        console.log('balanceToken0 after:', web3.utils.fromWei(balanceToken0After.toString()));

        const balanceETHAfter = await web3.eth.getBalance(currentAccount)
        console.log('ETH balance after:', web3.utils.fromWei(balanceETHAfter.toString()));

        console.log("Token diff: " + web3.utils.fromWei((balanceToken0After - balanceToken0Before).toString()));
        console.log("ETH diff: " + web3.utils.fromWei((balanceETHAfter - balanceETHBefore).toString()));

    } catch (error) {
        console.log(error);
    }
    callback();
}