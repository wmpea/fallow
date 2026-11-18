// npx hardhat run scripts/deploy.js --network <network>
// Env: FALLOW_SEED (string, optional), FALLOW_PRICE_ETH (optional, default 0)
const hre = require("hardhat");
const { keccak256, toUtf8Bytes, parseEther } = require("ethers");
const { deployFallow } = require("./lib/deploy");
const { defaultSeed } = require("../reference/terrain");

async function main() {
  const seed = process.env.FALLOW_SEED ? keccak256(toUtf8Bytes(process.env.FALLOW_SEED)) : defaultSeed();
  const price = parseEther(process.env.FALLOW_PRICE_ETH || "0");
  const { terrain, fallow, renderer, thresholds } = await deployFallow(hre.ethers, { seed, price });
  console.log("seed      ", seed);
  console.log("thresholds", thresholds);
  console.log("terrain   ", await terrain.getAddress());
  console.log("fallow    ", await fallow.getAddress());
  console.log("renderer  ", await renderer.getAddress());
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
