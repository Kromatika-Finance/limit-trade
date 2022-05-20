const SwapAggregatorAdapter = artifacts.require("SwapAggregatorAdapter");
const KromatikaMetaSwap = artifacts.require("KromatikaMetaSwap");
const LibERC20Adapter = artifacts.require("LibERC20Adapter");

module.exports = async function (deployer, network, accounts) {

  await deployer.deploy(LibERC20Adapter);
  await deployer.link(LibERC20Adapter, [SwapAggregatorAdapter, KromatikaMetaSwap]);

  await deployer.deploy(SwapAggregatorAdapter);
  await deployer.deploy(KromatikaMetaSwap);

  const aggregatorAdapter = await SwapAggregatorAdapter.deployed();

  const metaswapInstance = await KromatikaMetaSwap.deployed();

  // prepare the metaswap instance
  await metaswapInstance.createFlashWallet();
  await metaswapInstance.changeAdapter('SwapAggregator', aggregatorAdapter.address);
};
