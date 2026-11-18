// Exact JavaScript mirror of contracts/FallowTerrain.sol.
// Used to calibrate the terrain thresholds before deploy and to check parity in tests.
const { solidityPackedKeccak256, keccak256, toUtf8Bytes } = require("ethers");

const PARCELS = 32;
const SUB = 8;
const CELLS = 256;
const ONE = 65536;
const DIAG = 46341;
const EDGE_START = 53740;
const LAYER = { elevation: 0, moisture: 1, weather: 2 };
const CELL = { Water: 0, Sand: 1, Meadow: 2, Wood: 3, Rock: 4 };

// Solidity int256 division truncates toward zero
const div = (a, b) => Math.trunc(a / b);

const GRADS = [
  [ONE, 0], [-ONE, 0], [0, ONE], [0, -ONE],
  [DIAG, DIAG], [-DIAG, DIAG], [DIAG, -DIAG], [-DIAG, -DIAG],
];

function defaultSeed() {
  return keccak256(toUtf8Bytes("fallow-genesis"));
}

function createTerrain(seed) {
  const gradCache = new Map();

  function grad(layer, spacing, ix, iy) {
    const k = `${layer}:${spacing}:${ix}:${iy}`;
    let g = gradCache.get(k);
    if (!g) {
      const h = solidityPackedKeccak256(
        ["bytes32", "uint8", "uint8", "uint16", "uint16"],
        [seed, layer, spacing, ix, iy]
      );
      g = GRADS[Number(BigInt(h) & 7n)];
      gradCache.set(k, g);
    }
    return g;
  }

  function dot(layer, spacing, ix, iy, dx, dy) {
    const [gx, gy] = grad(layer, spacing, ix, iy);
    return div(gx * dx + gy * dy, ONE);
  }

  function fade(t) {
    const t3 = div(div(t * t, ONE) * t, ONE);
    return div(t3 * (div(t * (6 * t - 15 * ONE), ONE) + 10 * ONE), ONE);
  }

  function perlin(x, y, spacing, layer) {
    const x0 = Math.floor(x / spacing);
    const y0 = Math.floor(y / spacing);
    const fx = Math.floor(((x % spacing) * ONE) / spacing);
    const fy = Math.floor(((y % spacing) * ONE) / spacing);
    const n00 = dot(layer, spacing, x0, y0, fx, fy);
    const n10 = dot(layer, spacing, x0 + 1, y0, fx - ONE, fy);
    const n01 = dot(layer, spacing, x0, y0 + 1, fx, fy - ONE);
    const n11 = dot(layer, spacing, x0 + 1, y0 + 1, fx - ONE, fy - ONE);
    const u = fade(fx);
    const v = fade(fy);
    const a = n00 + div((n10 - n00) * u, ONE);
    const b = n01 + div((n11 - n01) * u, ONE);
    return a + div((b - a) * v, ONE);
  }

  function field(x, y, layer) {
    return div(6 * perlin(x, y, 72, layer) + 3 * perlin(x, y, 26, layer) + perlin(x, y, 9, layer), 10);
  }

  function falloff(x, y) {
    const dx = 2 * x - 255;
    const dy = 2 * y - 255;
    const d2 = dx * dx + dy * dy;
    const e = Math.max(Math.abs(dx), Math.abs(dy)) * 256;
    const edge = e > EDGE_START ? 4 * (e - EDGE_START) : 0;
    return div(68 * d2, 100) + edge;
  }

  const elevation = (x, y) => field(x, y, LAYER.elevation) - falloff(x, y);
  const moisture = (x, y) => field(x, y, LAYER.moisture);

  function cellAt(x, y, t) {
    const e = elevation(x, y);
    if (e < t.waterT) return CELL.Water;
    if (e < t.sandT) return CELL.Sand;
    if (e > t.rockT) return CELL.Rock;
    if (moisture(x, y) > t.woodT) return CELL.Wood;
    return CELL.Meadow;
  }

  // Thresholds from percentiles over the whole field: ~36% water, ~3% sand, top ~4.5% rock,
  // and the wettest ~18% of the remaining land is wood.
  function calibrate({ water = 0.36, sand = 0.39, rock = 0.955, wood = 0.82 } = {}) {
    const elev = [];
    for (let y = 0; y < CELLS; y++) for (let x = 0; x < CELLS; x++) elev.push(elevation(x, y));
    const sorted = [...elev].sort((a, b) => a - b);
    const pick = (q) => sorted[Math.floor(sorted.length * q)];
    const waterT = pick(water);
    const sandT = pick(sand);
    const rockT = pick(rock);
    const land = [];
    for (let y = 0; y < CELLS; y++)
      for (let x = 0; x < CELLS; x++) {
        const e = elev[y * CELLS + x];
        if (e >= sandT && e <= rockT) land.push(moisture(x, y));
      }
    land.sort((a, b) => a - b);
    const woodT = land[Math.floor(land.length * wood)];
    return { waterT, sandT, rockT, woodT };
  }

  return { seed, perlin, field, falloff, elevation, moisture, cellAt, calibrate };
}

module.exports = { createTerrain, defaultSeed, PARCELS, SUB, CELLS, CELL, LAYER };
