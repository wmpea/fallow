require("@nomicfoundation/hardhat-toolbox");
const { subtask } = require("hardhat/config");
const { TASK_COMPILE_SOLIDITY_GET_SOLC_BUILD } = require("hardhat/builtin-tasks/task-names");

const SOLC_VERSION = "0.8.28";

// Offline builds: LOCAL_SOLCJS=1 compiles with the solcjs package in node_modules
// instead of downloading a native compiler.
if (process.env.LOCAL_SOLCJS) {
  subtask(TASK_COMPILE_SOLIDITY_GET_SOLC_BUILD, async (args, hre, runSuper) => {
    if (args.solcVersion === SOLC_VERSION) {
      const solc = require("solc");
      return {
        compilerPath: require.resolve("solc/soljson.js"),
        isSolcJs: true,
        version: args.solcVersion,
        longVersion: solc.version(),
      };
    }
    return runSuper();
  });
}

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: SOLC_VERSION,
    settings: {
      optimizer: { enabled: true, runs: 200 },
      evmVersion: "cancun",
    },
  },
  networks: {
    // Any EVM network: RPC_URL=... PRIVATE_KEY=... npx hardhat run scripts/deploy.js --network live
    ...(process.env.RPC_URL
      ? { live: { url: process.env.RPC_URL, accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [] } }
      : {}),
    hardhat: {
      // Keep everything, renders included, under the per-transaction gas cap (EIP-7825)
      blockGasLimit: 16_777_216,
    },
  },
  mocha: { timeout: 600_000 },
};
