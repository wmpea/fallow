const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");
const { deployFallow } = require("../scripts/lib/deploy");
const { createTerrain, CELL, PARCELS, SUB } = require("../reference/terrain");

const DAY = 86400;
const STAGE = { Wild: 0n, Tilled: 1n, Sown: 2n, Harvest: 3n };
const PRICE = ethers.parseEther("0.01");

async function fixture() {
  const [owner, alice, bob] = await ethers.getSigners();
  const d = await deployFallow(ethers, { price: PRICE });
  const ref = createTerrain(d.seed);
  // first land (meadow) parcel and first sea parcel, from the JS mirror
  let land, sea;
  for (let id = 0; id < PARCELS * PARCELS && (land === undefined || sea === undefined); id++) {
    const c = ref.cellAt((id % PARCELS) * SUB + SUB / 2, Math.floor(id / PARCELS) * SUB + SUB / 2, d.thresholds);
    if (c === CELL.Meadow && land === undefined && id > 300) land = id;
    if (c === CELL.Water && sea === undefined) sea = id;
  }
  return { ...d, ref, owner, alice, bob, land, sea };
}

async function nextDay() {
  // move to the start of the next UTC day (plus a minute)
  const now = await time.latest();
  await time.increaseTo((Math.floor(now / DAY) + 1) * DAY + 60);
}

function decodeTokenURI(uri) {
  const json = JSON.parse(Buffer.from(uri.split(",")[1], "base64").toString("utf8"));
  const svg = Buffer.from(json.image.split(",")[1], "base64").toString("utf8");
  return { json, svg };
}

module.exports = { DAY, STAGE, PRICE, fixture, nextDay, decodeTokenURI };
