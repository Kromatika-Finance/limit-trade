const Kromatika = artifacts.require("Kromatika");

module.exports = async function(deployer) {
	await deployer.deploy(Kromatika);
}
