const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture, time } = require("@nomicfoundation/hardhat-network-helpers");
const { DAY, STAGE, PRICE, fixture, nextDay, decodeTokenURI } = require("./helpers");
const { CELL, PARCELS, SUB } = require("../reference/terrain");

describe("FallowRenderer", function () {
  it("knows the seasons (year counted from March 1st)", async function () {
    const { renderer } = await loadFixture(fixture);
    const dayOf = (iso) => Math.floor(Date.parse(iso) / 1000 / DAY);
    const cases = [
      ["2026-03-01", 0, 0],
      ["2026-05-31", 0, 91],
      ["2026-06-15", 1, 14],
      ["2026-09-01", 2, 0],
      ["2026-12-01", 3, 0],
      ["2028-02-29", 3, 90],
    ];
    for (const [iso, season, daysIn] of cases) {
      const [s, d] = await renderer.seasonOn(dayOf(iso));
      expect([Number(s), Number(d)]).to.deep.equal([season, daysIn], iso);
    }
  });

  it("returns base64 JSON with an SVG image and traits", async function () {
    const { fallow, alice, land } = await loadFixture(fixture);
    await fallow.connect(alice).mint(land, { value: PRICE });
    await fallow.connect(alice).tend(land);
    const { json, svg } = decodeTokenURI(await fallow.tokenURI(land));
    expect(json.name).to.match(/^Fallow \d\d,\d\d$/);
    expect(svg.startsWith("<svg")).to.equal(true);
    expect(svg.endsWith("</svg>")).to.equal(true);
    const traits = Object.fromEntries(json.attributes.map((a) => [a.trait_type, a.value]));
    expect(traits.Stage).to.equal("Tilled");
    expect(traits.Loam).to.equal(1);
    expect(traits.Streak).to.equal(1);
  });

  it("renders under the 16.7M per-transaction gas cap (EIP-7825)", async function () {
    const { fallow, renderer, terrain, alice, land } = await loadFixture(fixture);
    await fallow.connect(alice).mint(land, { value: PRICE });
    const CAP = 16_777_216n;
    const deployGas = (await terrain.deploymentTransaction().wait()).gasUsed;
    const tendGas = await fallow.connect(alice).tend.estimateGas(land);
    const probe = await (await ethers.getContractFactory("GasProbe")).deploy();
    const measure = async (contract, fn, args) => {
      const [used, ok] = await probe.measure(await contract.getAddress(), contract.interface.encodeFunctionData(fn, args));
      expect(ok).to.equal(true, `${fn} failed`);
      return used;
    };
    const uriGas = await measure(fallow, "tokenURI", [land]);
    const mapGas = await measure(renderer, "mapSvg", [20500]);
    const m = (g) => (Number(g) / 1e6).toFixed(1) + "M";
    console.log(`      terrain deploy ${m(deployGas)} · tend ${Number(tendGas) / 1000}k · tokenURI ${m(uriGas)} · mapSvg ${m(mapGas)}`);
    expect(deployGas).to.be.lessThan(CAP);
    expect(tendGas).to.be.lessThan(120_000n);
    expect(uriGas).to.be.lessThan(CAP);
    expect(mapGas).to.be.lessThan(CAP);
  });

  it("can be swapped until it is locked", async function () {
    const { fallow, renderer, alice } = await loadFixture(fixture);
    await expect(fallow.connect(alice).setRenderer(alice.address)).to.be.reverted;
    await fallow.setRenderer(await renderer.getAddress());
    await fallow.lockRenderer();
    await expect(fallow.setRenderer(alice.address)).to.be.revertedWithCustomError(fallow, "RendererIsLocked");
  });
});
