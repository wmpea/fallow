const { createTerrain, defaultSeed } = require("../../reference/terrain");

// Calibrates the terrain for a seed, then deploys Terrain -> Fallow -> Renderer and wires them.
async function deployFallow(ethers, { seed = defaultSeed(), price = 0n } = {}) {
  const thresholds = createTerrain(seed).calibrate();
  const { waterT, sandT, rockT, woodT } = thresholds;

  const terrain = await (await ethers.getContractFactory("FallowTerrain")).deploy(seed, waterT, sandT, rockT, woodT);
  await terrain.waitForDeployment();

  const fallow = await (await ethers.getContractFactory("Fallow")).deploy(await terrain.getAddress(), price);
  await fallow.waitForDeployment();

  const renderer = await (await ethers.getContractFactory("FallowRenderer")).deploy(
    await fallow.getAddress(),
    await terrain.getAddress()
  );
  await renderer.waitForDeployment();
  await (await fallow.setRenderer(await renderer.getAddress())).wait();

  return { terrain, fallow, renderer, seed, thresholds };
}

module.exports = { deployFallow };
