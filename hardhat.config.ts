import { HardhatUserConfig } from 'hardhat/config';
import '@nomicfoundation/hardhat-toolbox';
import "@nomiclabs/hardhat-etherscan";
import "hardhat-contract-sizer";
require('dotenv').config();

const config: HardhatUserConfig = {
  solidity: {
    version: '0.8.20',
    settings: {
      viaIR: true,
      optimizer: {
        enabled: true,
        runs: 200,
        details: {
          constantOptimizer: true,
        },
      },
    }
  },
  networks: {
    // for testnet
    localhost: {
      timeout: 120000,
    },
    hardhat: {
      allowUnlimitedContractSize: true
    },
    'base-sepolia': {
      url: 'https://sepolia.base.org',
      accounts: [process.env.WALLET_KEY as string],
    },
  },
  defaultNetwork: 'hardhat',
};

export default config;

