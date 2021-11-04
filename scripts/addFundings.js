const LimitOrderManager = artifacts.require("LimitOrderManager");
const Kromatika = artifacts.require("Kromatika");

module.exports = async(callback) => {


    try {

        const accounts = await web3.eth.getAccounts();
        const currentAccount = accounts[0];

        const limitOrderManager = await LimitOrderManager.deployed();

        const balance = await limitOrderManager.funding(currentAccount);
        console.log(balance.toString());
        const funding = await limitOrderManager.reservedWeiFunds(currentAccount);
        console.log(funding.toString());

        const quote = await limitOrderManager.quoteKROM(funding.toString());
        console.log(quote.toString());

        const underfunded = await limitOrderManager.isUnderfunded(currentAccount);
        if (underfunded.underfunded) {
            const kromatika = await Kromatika.deployed();
            const amount = underfunded.amount;
            console.log(amount.toString())
            await kromatika.approve(
                limitOrderManager.address,
                amount,
                {from: currentAccount}
            );
            await limitOrderManager.addFunding(amount);
        }

    } catch (error) {
        console.log(error);
    }
    callback();
}