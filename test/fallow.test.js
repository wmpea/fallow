const { expect } = require("chai");
const { loadFixture, time } = require("@nomicfoundation/hardhat-network-helpers");
const { DAY, STAGE, PRICE, fixture, nextDay, decodeTokenURI } = require("./helpers");
const { CELL, PARCELS, SUB } = require("../reference/terrain");

describe("FallowTerrain", function () {
  it("matches the JS reference cell for cell", async function () {
    const { terrain, ref, thresholds } = await loadFixture(fixture);
    const cells = [];
    for (let k = 0; k < 160; k++) cells.push([(k * 97 + 13) % 256, (k * 61 + 7) % 256]);
    for (const [x, y] of cells) {
      expect(await terrain.elevation(x, y)).to.equal(BigInt(ref.elevation(x, y)), `elevation ${x},${y}`);
      expect(await terrain.cellAt(x, y)).to.equal(BigInt(ref.cellAt(x, y, thresholds)), `cell ${x},${y}`);
    }
  });

  it("agrees with the JS reference on which parcels are sea", async function () {
    const { terrain, ref, thresholds } = await loadFixture(fixture);
    for (let id = 0; id < PARCELS * PARCELS; id += 7) {
      const c = ref.cellAt((id % PARCELS) * SUB + SUB / 2, Math.floor(id / PARCELS) * SUB + SUB / 2, thresholds);
      expect(await terrain.isSea(id)).to.equal(c === CELL.Water, `parcel ${id}`);
    }
  });

  it("computes whole blocks identically (the path renders use)", async function () {
    const { terrain, ref, thresholds } = await loadFixture(fixture);
    const block = await terrain.cells(120, 96, 24, 24, 1);
    const bytes = Buffer.from(block.slice(2), "hex");
    for (let j = 0; j < 24; j++)
      for (let i = 0; i < 24; i++) {
        expect(bytes[j * 24 + i]).to.equal(ref.cellAt(120 + i, 96 + j, thresholds), `cell ${120 + i},${96 + j}`);
      }
    const parcels = Buffer.from((await terrain.parcels()).slice(2), "hex");
    expect(parcels.length).to.equal(1024);
    for (let id = 0; id < 1024; id += 5) {
      expect(parcels[id]).to.equal(ref.cellAt((id % 32) * 8 + 4, Math.floor(id / 32) * 8 + 4, thresholds), `parcel ${id}`);
    }
  });

  it("is an island: the border is always sea", async function () {
    const { terrain } = await loadFixture(fixture);
    for (let i = 0; i < PARCELS; i++) {
      expect(await terrain.isSea(i)).to.equal(true);
      expect(await terrain.isSea(i * PARCELS)).to.equal(true);
    }
  });
});

describe("Fallow: minting", function () {
  it("mints a coordinate at the set price, once", async function () {
    const { fallow, alice, bob, land } = await loadFixture(fixture);
    await expect(fallow.connect(alice).mint(land, { value: 0 })).to.be.revertedWithCustomError(fallow, "WrongPrice");
    await fallow.connect(alice).mint(land, { value: PRICE });
    expect(await fallow.ownerOf(land)).to.equal(alice.address);
    expect(await fallow.totalMinted()).to.equal(1n);
    await expect(fallow.connect(bob).mint(land, { value: PRICE })).to.be.reverted;
    await expect(fallow.connect(bob).mint(1024, { value: PRICE })).to.be.revertedWithCustomError(fallow, "OutOfRange");
  });

  it("lets the owner withdraw mint proceeds", async function () {
    const { fallow, owner, alice, land } = await loadFixture(fixture);
    await fallow.connect(alice).mint(land, { value: PRICE });
    await expect(fallow.withdraw()).to.changeEtherBalances([owner, fallow], [PRICE, -PRICE]);
  });
});

describe("Fallow: tending", function () {
  async function minted() {
    const f = await loadFixture(fixture);
    await f.fallow.connect(f.alice).mint(f.land, { value: PRICE });
    await f.fallow.connect(f.alice).mint(f.sea, { value: PRICE });
    return f;
  }

  it("cycles wild -> tilled -> sown -> harvest -> tilled, once a day", async function () {
    const { fallow, alice, land } = await minted();
    expect(await fallow.stageOf(land)).to.equal(STAGE.Wild);
    const expected = [STAGE.Tilled, STAGE.Sown, STAGE.Harvest, STAGE.Tilled, STAGE.Sown];
    for (const s of expected) {
      await fallow.connect(alice).tend(land);
      expect(await fallow.stageOf(land)).to.equal(s);
      await expect(fallow.connect(alice).tend(land)).to.be.revertedWithCustomError(fallow, "AlreadyTendedToday");
      await nextDay();
    }
  });

  it("only the owner can tend, and sea plots can't be farmed", async function () {
    const { fallow, alice, bob, land, sea } = await minted();
    await expect(fallow.connect(bob).tend(land)).to.be.revertedWithCustomError(fallow, "NotPlotOwner");
    await expect(fallow.connect(alice).tend(sea)).to.be.revertedWithCustomError(fallow, "SeaPlot");
  });

  it("builds a streak on consecutive days and loam faster as it grows", async function () {
    const { fallow, alice, land } = await minted();
    let loam = 0;
    for (let day = 1; day <= 15; day++) {
      await fallow.connect(alice).tend(land);
      loam += 1 + Math.floor(day / 7);
      expect(await fallow.streakOf(land)).to.equal(BigInt(day));
      expect(await fallow.loamOf(land)).to.equal(BigInt(loam));
      await nextDay();
    }
  });

  it("breaks the streak after a missed day, before anyone touches storage", async function () {
    const { fallow, alice, land } = await minted();
    await fallow.connect(alice).tend(land);
    await nextDay();
    await fallow.connect(alice).tend(land);
    expect(await fallow.streakOf(land)).to.equal(2n);
    await nextDay();
    expect(await fallow.streakOf(land)).to.equal(2n); // still today's grace
    await nextDay();
    expect(await fallow.streakOf(land)).to.equal(0n); // a day was missed
    const loamBefore = await fallow.loamOf(land);
    await fallow.connect(alice).tend(land);
    expect(await fallow.streakOf(land)).to.equal(1n);
    expect(await fallow.loamOf(land)).to.equal(loamBefore + 1n); // loam never goes down
  });

  it("goes back to wild after 30 untended days", async function () {
    const { fallow, alice, land } = await minted();
    await fallow.connect(alice).tend(land);
    await nextDay();
    await fallow.connect(alice).tend(land);
    expect(await fallow.stageOf(land)).to.equal(STAGE.Sown);
    await time.increase(30 * DAY);
    expect(await fallow.stageOf(land)).to.equal(STAGE.Sown); // day 30: hanging on
    await time.increase(DAY);
    expect(await fallow.stageOf(land)).to.equal(STAGE.Wild); // day 31: gone wild
    await fallow.connect(alice).tend(land);
    expect(await fallow.stageOf(land)).to.equal(STAGE.Tilled);
  });

  it("resets the streak but keeps loam when the land changes hands", async function () {
    const { fallow, alice, bob, land } = await minted();
    for (let i = 0; i < 3; i++) {
      await fallow.connect(alice).tend(land);
      await nextDay();
    }
    const loam = await fallow.loamOf(land);
    await expect(fallow.connect(alice).transferFrom(alice.address, bob.address, land))
      .to.emit(fallow, "MetadataUpdate")
      .withArgs(land);
    expect(await fallow.streakOf(land)).to.equal(0n);
    expect(await fallow.loamOf(land)).to.equal(loam);
    await fallow.connect(bob).tend(land);
    expect(await fallow.streakOf(land)).to.equal(1n);
  });

  it("emits ERC-4906 MetadataUpdate on every tend", async function () {
    const { fallow, alice, land } = await minted();
    await expect(fallow.connect(alice).tend(land)).to.emit(fallow, "MetadataUpdate").withArgs(land);
    expect(await fallow.supportsInterface("0x49064906")).to.equal(true);
  });
});
