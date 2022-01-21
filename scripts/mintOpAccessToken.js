const OpAccessToken = artifacts.require("OpAccessToken")

module.exports = async(callback) => {

    try {

        const accessTokenInstance = await OpAccessToken.deployed();

        const calldatas = [];

        // const tokenArray = [
        //     '0x254e6895a051E738b81fAFd038dFb01d4404566A',
        //     '0x1793f0479842af9d573f952ec0b8293135d6411f',
        //     '0xF0d0be6Ac03901d4d659005fafb687abbD2DBE91',
        //     '0x78d4886610F72be44919Db193e28Eb3Ae2F4C133',
        //     '0xA7b42237Ed91E37d54787E5F02687DB4Aa98C8aE',
        //     '0xa8FDCf76C394E108c15357D7EE72bFb3a04bBcCc',
        //     '0x177069e924B4DB4345a9ac83589e71D5d82535dd',
        //     '0xE73AdBa1d58C283f1041c090806515C70a326214',
        //     '0x5fefdb8e576bda70f63e8e8edaac7426c67c6b5a',
        //     '0x137a114Ad2c138c69acd81dFDBEA65C903A71CeF',
        //     '0x9B3493aDB33004fd7a63Fb1fe332D9CD8143995d',
        //     '0xF41581B6cEc6FB011C063F4cE6497571bb0781e3'
        // ]

        // const tokenArray = [
        //     '0x24feb1c880b8b4154a58c6d2461a646b22e18b28',
        //     '0x3fc7a3c3a12b10db8d6ec4a5f206d9e70dfe2787',
        //     '0x4c29342d3d7121da87109e9bb444451984de7386',
        //     '0x52af320475d8bbfff057193c6ea431c15fbfc2da',
        //     '0x5af84f1318241b4224ecfc9e6d4e97a3118cd38f',
        //     '0x6232d7a6085d0ab8f885292078eeb723064a376b',
        //     '0x639b837e9b67acc68ecc6161d5ae7f419e3b9657',
        //     '0x7d928193cdfcce19b382877f995f0be20393d913',
        //     '0xa78ad1cf17d1d132144f18d07b42e479e2836cff',
        //     '0xbac5282c8c03dd4e519b20c31d8da921dd469112',
        //     '0xc2ec00aefebe4e4997a9d4510115dcac74558795',
        //     '0xc4e83bafd87cd2ea644d57ff13074a68374f81c9',
        //     '0xcb114805b901f7a9c38d5675272ef26459a7d805',
        //     '0xcc72e72ac30f11b9df234599158db2b9ca020cd5',
        //     '0xd1463bbfcf9348edae567a39436f73ac4964ed88',
        //     '0xd3f714357a3a5ab971941ca475a006814edd0d2b',
        //     '0xdc1a3e2a07d38d019b83b0051d77826f1a2c8c6d',
        //     '0xdddd34f88b475dae9fef76af218b00cca0d7a06a',
        //     '0xde1c74c9561cee23fdf8b98ba387960538ff51a6'
        // ];

        // const tokenArray = [
        //     '0x0178fe1cb8e278b8c055e2aead91177c1a66f7f5',
        //     '0x0b99363648efea66689d58a553bb015957083c57',
        //     '0x13571ad2c5e0edee0483440242d5e89b47efd63c',
        //     '0x19bc334ab56c18128c188a6543acb49c84b43c2e',
        //     '0x1e7ab566433f4554f326960853d13b539c1a2259',
        //     '0x29bf6652e795c360f7605be0fcd8b8e4f29a52d4',
        //     '0x35abbca84d7e6a4effd415d0d971b8de59c233f9',
        //     '0x3f5653b3b879d078ad1005b25a6acf1435bed778',
        //     '0x47799ac6657a6af5b25b317f8b459b19cb72bcab',
        //     '0x590f7796c7573fafed2fcf50f3dbd9ef79fe51b1',
        //     '0x5946380b891b96619ed931b24c2ad2adf83e2d87',
        //     '0x6e82554d7c496baccc8d0bcb104a50b772d22a1f',
        //     '0x7e16d7f1b6056e790eeb3efc03b1015eee5436a1',
        //     '0x922cb5dd2d9a4da1d5448602f5ded36a6e866f42',
        //     '0x985f3d1a953e0e0b0741d811e518d20dcc4317a2',
        //     '0xa5c2164bee8a08221a235affa59f4b0471bdc59c',
        //     '0xafff3113be5c3923e87ff4816b003116630dc571',
        //     '0xbab578f490ef5b34470e390a74749655acf0b7c4',
        //     '0xd565365c2f16d5269387c44f6fcf9359a22451d2',
        //     '0xd8480758270d670e401fdac86925cfc225a9dfe0',
        //     '0xdbaabc182e5fcebf216c353a3ebe32cdb7390094',
        //     '0xde62454e1f6f7ef04a70a79edd44936aaa5259ae',
        //     '0xe63feebd79d41b38b5dc5b8ff3682df74fb28d09',
        //     '0xe995e2a9ae5210feb6dd07618af28ec38b2d7ce1',
        //     '0xea1aeb8aae7ded695a17972a0a7de7769f4ba1e9',
        //     '0xf3700faff4cb894e9a1391c7d7d31a29c0b7c56b',
        //     '0xf41581b6cec6fb011c063f4ce6497571bb0781e3',
        //     '0x2d1bdC590Cb736097Bc5577c8974e28dc48F5ECc'
        // ];

        const tokenArray = [
            '0x95F91DA5d7FcD6f8CD3F224fB00ECe70897404Da',
            '0xfF81bf22750a44Ec9cd83F7F789C24356C13e683'
        ];

        for (let i=0; i< tokenArray.length; i++) {
            calldatas.push(web3.eth.abi.encodeFunctionCall({
                name: 'mint',
                type: 'function',
                inputs: [{
                    type: 'address',
                    name: '_to'
                }]
            }, [tokenArray[i]]));
        }

        console.log(calldatas);

        const receipt = await accessTokenInstance.multicall(calldatas);
        console.log(receipt);

    } catch (error) {
        console.log(error);
    }
    callback();

};