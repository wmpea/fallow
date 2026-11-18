// Renders real SVGs from the contracts into renders/, after simulating a couple of months of
// tending on a local Hardhat chain.
//
//   npm run render            (LOCAL_SOLCJS=1 npm run render to compile offline)
//
// Each render is a multi-million-gas view call, and the local node holds on to memory after
// big calls, so every job runs in its own process and replays the same deterministic simulation.
const { spawnSync } = require("child_process");
const fs = require("fs");
const path = require("path");
const { createTerrain, CELL, PARCELS, SUB } = require("../reference/terrain");

const OUT = path.join(__dirname, "..", "renders");
const DAY = 86400;
const dayOf = (iso) => Math.floor(Date.parse(iso + "T00:00:00Z") / 1000 / DAY);
const isoOf = (day) => new Date(day * DAY * 1000).toISOString().slice(0, 10);

const FINAL = dayOf("2027-12-11"); // mid winter sweep
const START = FINAL - 61;
const SEASON_DAYS = {
  spring: dayOf("2027-04-30"),
  summer: dayOf("2027-07-30"),
  autumn: dayOf("2027-10-30"),
  winter: dayOf("2028-01-30"),
};

const JOBS = {
  "stage-a": { until: FINAL - 2, hero: [FINAL - 2] },
  "stage-b": { until: FINAL - 1, hero: [FINAL - 1] },
  "stage-c": { until: FINAL, hero: [FINAL] },
  maps: { until: FINAL, maps: [FINAL - 7, FINAL, FINAL + 7], uri: true },
  "seasons-a": { until: FINAL, seasons: ["spring", "summer"] },
  "seasons-b": { until: FINAL, seasons: ["autumn", "winter"] },
};

// deterministic 0..1 from integers
function hash01(...xs) {
  let h = 2166136261;
  for (const x of xs) {
    h ^= x;
    h = Math.imul(h, 16777619) >>> 0;
    h ^= h >>> 13;
  }
  return (h >>> 0) / 4294967296;
}

// A farmable parcel with terrain inside the plot and land on all sides.
function pickHero(ref, t, parcels) {
  let best = null;
  for (let id = 0; id < PARCELS * PARCELS; id++) {
    const px = id % PARCELS;
    const py = Math.floor(id / PARCELS);
    if (parcels[id] !== CELL.Meadow || px < 2 || py < 2 || px > PARCELS - 3 || py > PARCELS - 3) continue;
    let landAround = true;
    for (let dy = -1; dy <= 1; dy++)
      for (let dx = -1; dx <= 1; dx++) if (parcels[(py + dy) * PARCELS + px + dx] === CELL.Water) landAround = false;
    if (!landAround) continue;
    const count = [0, 0, 0, 0, 0];
    for (let j = 0; j < SUB; j++) for (let i = 0; i < SUB; i++) count[ref.cellAt(px * SUB + i, py * SUB + j, t)]++;
    const meadow = count[CELL.Meadow] / 64;
    if (meadow < 0.5 || meadow > 0.85) continue;
    const kinds = count.filter((c, k) => k !== CELL.Meadow && c >= 3).length;
    const score = kinds * 10 + (1 - Math.abs(meadow - 0.68));
    if (!best || score > best.score) best = { id, px, py, score };
  }
  return best;
}

async function simulate(hre, until) {
  const { ethers } = hre;
  const { time } = require("@nomicfoundation/hardhat-network-helpers");
  const { deployFallow } = require("./lib/deploy");

  const d = await deployFallow(ethers);
  const [deployer, farmer] = await ethers.getSigners();
  const ref = createTerrain(d.seed);
  const parcels = Buffer.from((await d.terrain.parcels()).slice(2), "hex");
  const hero = pickHero(ref, d.thresholds, parcels);
  if (!hero) throw new Error("no hero parcel for this seed");

  // who tends what, and when (days relative to FINAL)
  const plans = new Map(); // tokenId -> (day) => boolean
  plans.set(hero.id, () => true);
  const neighborPlans = {
    "-1,-1": (k) => k >= -50 && k <= -36, // stopped 36 days ago: back to wild
    "0,-1": (k) => k >= -40,
    "1,-1": (k) => k >= -13 && k <= -3, // stopped recently: stage frozen
    "-1,0": null, // never claimed
    "1,0": (k) => k >= -25,
    "-1,1": (k) => k >= -30 && k % 2 === 0, // every other day
    "0,1": (k) => k >= -9,
    "1,1": (k) => k >= -55 && k <= -1,
  };
  for (const [key, plan] of Object.entries(neighborPlans)) {
    if (!plan) continue;
    const [dx, dy] = key.split(",").map(Number);
    plans.set((hero.py + dy) * PARCELS + hero.px + dx, plan);
  }
  const heroBlock = new Set(
    [-1, 0, 1].flatMap((dy) => [-1, 0, 1].map((dx) => (hero.py + dy) * PARCELS + hero.px + dx))
  );
  for (let id = 0; id < PARCELS * PARCELS; id++) {
    if (parcels[id] === CELL.Water || heroBlock.has(id) || hash01(id, 1) > 0.55) continue;
    const diligence = [0, 0.3, 0.6, 0.9, 1][Math.floor(hash01(id, 2) * 5)];
    plans.set(id, (k) => k >= -12 && hash01(id, 3, k + 100) < diligence);
  }

  await time.increaseTo(START * DAY + 3600);
  for (const id of plans.keys()) {
    if (parcels[id] === CELL.Water) continue;
    await d.fallow.connect(farmer).mint(id);
  }
  for (let day = START; day <= until; day++) {
    for (const [id, plan] of plans) {
      if (parcels[id] !== CELL.Water && plan(day - FINAL)) await d.fallow.connect(farmer).tend(id);
    }
    if (day < until) await time.increaseTo((day + 1) * DAY + 3600);
  }
  return { ...d, hero };
}

async function runJob(name) {
  const hre = require("hardhat");
  const job = JOBS[name];
  const { fallow, renderer, hero } = await simulate(hre, job.until);
  const coord = `${String(hero.px).padStart(2, "0")}-${String(hero.py).padStart(2, "0")}`;
  const write = (file, text) => {
    fs.writeFileSync(path.join(OUT, file), text);
    console.log(`  wrote renders/${file}`);
  };
  const [, stage, streak, loam] = await fallow.plotOf(hero.id);
  console.log(`  ${name}: hero ${coord} on ${isoOf(job.until)} · stage ${stage} · streak ${streak} · loam ${loam}`);

  for (const day of job.hero || []) write(`hero-${coord}-${isoOf(day)}.svg`, await renderer.tokenSvg(hero.id, day));
  for (const day of job.maps || []) write(`map-${isoOf(day)}.svg`, await renderer.mapSvg(day));
  for (const s of job.seasons || []) write(`hero-${coord}-${s}.svg`, await renderer.tokenSvg(hero.id, SEASON_DAYS[s]));
  if (job.uri) {
    const json = JSON.parse(Buffer.from((await fallow.tokenURI(hero.id)).split(",")[1], "base64").toString());
    write(`token-${coord}.json`, JSON.stringify({ ...json, image: "(see hero svg)" }, null, 2) + "\n");
  }
}

function gallery() {
  const files = fs.readdirSync(OUT).filter((f) => f.endsWith(".svg")).sort();
  const cards = files
    .map((f) => `<figure><img src="${f}" alt="${f}"><figcaption>${f.replace(".svg", "")}</figcaption></figure>`)
    .join("\n");
  fs.writeFileSync(
    path.join(OUT, "index.html"),
    `<!doctype html><meta charset="utf-8"><title>Fallow renders</title>
<style>body{margin:0;padding:32px;background:#0f0e0b;color:#a39b8a;font:13px ui-monospace,monospace}
main{display:grid;grid-template-columns:repeat(auto-fill,minmax(320px,1fr));gap:28px}
img{width:100%;display:block}figcaption{margin-top:8px}</style>
<h1 style="color:#e8e2d4;font-size:16px;font-weight:500">Fallow · rendered by the contracts</h1>
<main>${cards}</main>\n`
  );
  console.log("  wrote renders/index.html");
}

if (process.env.RENDER_JOB) {
  runJob(process.env.RENDER_JOB).catch((e) => {
    console.error(e);
    process.exitCode = 1;
  });
} else {
  fs.mkdirSync(OUT, { recursive: true });
  for (const name of Object.keys(JOBS)) {
    const r = spawnSync("npx", ["hardhat", "run", __filename], {
      stdio: "inherit",
      env: { ...process.env, RENDER_JOB: name },
    });
    if (r.status !== 0) process.exit(r.status || 1);
  }
  gallery();
}
