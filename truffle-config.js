require("dotenv").config();
const HDWalletProvider = require('truffle-hdwallet-provider');


module.exports = {
  networks: {
    development: {
      host: "localhost",
      port: 7545,
      network_id: 5777
    },
    testnet: {
        provider: () => new HDWalletProvider(process.env.MNEMONIC, `https://data-seed-prebsc-2-s1.binance.org:8545`),
        network_id: 97,
        confirmations: 5,
        timeoutBlocks: 200,
        skipDryRun: true
    },
    bsc: {
        provider: () => new HDWalletProvider(process.env.MNEMONIC, `https://bsc-dataseed1.binance.org`),
        network_id: 56,
        confirmations: 10,
        timeoutBlocks: 200,
        skipDryRun: true
    },
  },
  compilers: {
    solc: {
      version: "0.5.16"
    }
  }
};
