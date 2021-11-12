const LimitOrderManager = artifacts.require("LimitOrderManager");
const Kromatika = artifacts.require("Kromatika");

module.exports = async(callback) => {


    try {

        const accounts = await web3.eth.getAccounts();
        const currentAccount = accounts[0];

        const limitOrderManager = await LimitOrderManager.deployed();

        let targetGasPrice = web3.utils.toWei("10", "gwei");

        const kromatika = await Kromatika.deployed();
        const amount = web3.utils.toWei('100');
        console.log(amount.toString())
        await kromatika.approve(
            limitOrderManager.address,
            amount,
            {from: currentAccount}
        );

        // await limitOrderManager.setTargetGasPrice(targetGasPrice);
        // await limitOrderManager.addFunding(amount);

        const calldatas = [];
        // calldatas.push(web3.eth.abi.encodeFunctionCall({
        //     name: 'setTargetGasPrice',
        //     type: 'function',
        //     inputs: [{
        //         type: 'uint256',
        //         name: 'targetGasPrice'
        //     }]
        // }, [targetGasPrice]));

        calldatas.push(web3.eth.abi.encodeFunctionCall({
            name: 'addFunding',
            type: 'function',
            inputs: [{
                type: 'uint256',
                name: 'amount'
            }]
        }, [amount]));

        console.log(calldatas);

        const receipt = await limitOrderManager.multicall(calldatas);
        console.log(receipt);
    } catch (error) {
        console.log(error);
    }
    callback();
}