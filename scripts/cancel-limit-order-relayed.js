const LimitOrderManager = artifacts.require("LimitOrderManager");
const IERC20 = artifacts.require("IERC20");

module.exports = async(callback) => {

    try {

        const accounts = await web3.eth.getAccounts();
        const currentAccount = accounts[0];

        const tradeInstance = await LimitOrderManager.deployed();

        const tokenId = "2";

        // encode function call
        const calldata = web3.eth.abi.encodeFunctionCall(
            {
                "inputs": [
                    {
                        "internalType": "uint256",
                        "name": "_tokenId",
                        "type": "uint256"
                    }
                ],
                "name": "cancelLimitOrder",
                "outputs": [
                    {
                        "internalType": "uint256",
                        "name": "_amount0",
                        "type": "uint256"
                    },
                    {
                        "internalType": "uint256",
                        "name": "_amount1",
                        "type": "uint256"
                    }
                ],
                "stateMutability": "nonpayable",
                "type": "function"
            }, [tokenId])

        const calldatas = [];
        calldatas.push(calldata);

        const nonce = await web3.eth.getTransactionCount(currentAccount, 'pending');
        const hashKey = web3.utils.keccak256(web3.eth.abi.encodeParameters(['bytes[]','address', 'uint256'], [calldatas, currentAccount, nonce]));

        let signature = await web3.eth.sign(hashKey, currentAccount);

        const receipt = await tradeInstance.relayedCall(calldatas, signature, currentAccount, nonce, {from: currentAccount});
        console.log('receipt:', receipt);

    } catch (error) {
        console.log(error);
    }
    callback();

};