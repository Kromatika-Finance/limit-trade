const SwapAggregatorAdapter = artifacts.require("SwapAggregatorAdapter");
const KromatikaMetaSwap = artifacts.require("MetaSwapRouter");

module.exports = async function(deployer) {
    //await deployer.deploy(SwapAggregatorAdapter);
    await deployer.deploy(KromatikaMetaSwap);

    const aggregatorAdapter = await SwapAggregatorAdapter.deployed();
    const metaswap = await KromatikaMetaSwap.deployed();

    const targetGasPrice = await web3.eth.getGasPrice();

    await metaswap.createFlashWallet({gasPrice: targetGasPrice});
    await metaswap.addAdapter('SwapAggregator', aggregatorAdapter.address, {gasPrice: targetGasPrice});
}
