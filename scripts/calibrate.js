// Prints the terrain thresholds for a seed, plus an ASCII preview of the island.
//   node scripts/calibrate.js [seed-string]
const { keccak256, toUtf8Bytes } = require("ethers");
const { createTerrain, defaultSeed, PARCELS, SUB, CELL } = require("../reference/terrain");

const seed = process.argv[2] ? keccak256(toUtf8Bytes(process.argv[2])) : defaultSeed();
const terrain = createTerrain(seed);
const t = terrain.calibrate();

const glyph = { [CELL.Water]: "~", [CELL.Sand]: ".", [CELL.Meadow]: '"', [CELL.Wood]: "♣", [CELL.Rock]: "^" };
let sea = 0;
const rows = [];
for (let py = 0; py < PARCELS; py++) {
  let row = "";
  for (let px = 0; px < PARCELS; px++) {
    const c = terrain.cellAt(px * SUB + SUB / 2, py * SUB + SUB / 2, t);
    if (c === CELL.Water) sea++;
    row += glyph[c];
  }
  rows.push(row);
}
console.log(rows.join("\n"));
console.log(`\nseed      ${seed}`);
console.log(`thresholds ${JSON.stringify(t)}`);
console.log(`sea plots ${sea} / ${PARCELS * PARCELS}  ·  farmable ${PARCELS * PARCELS - sea}`);

module.exports = { seed, thresholds: t };
