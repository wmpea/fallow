// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @title FallowTerrain
/// @notice The island. Nothing here is stored: every one of the 256x256 cells is computed
///         from the seed with fixed-point Perlin noise (after 0xPARC's "On-chain Procedural
///         Generation"), then pulled down toward the edges so the field is always an island.
/// @dev    Immutable by design: the game contract reads it to decide which parcels are sea.
///         `reference/terrain.js` mirrors this math exactly; the tests check parity.
///         `cells()` computes a whole block at once: each lattice gradient is hashed once and
///         each column's and row's offsets and fade curves are computed once, which is what
///         keeps full renders affordable as view calls.
contract FallowTerrain {
    enum Cell {
        Water,
        Sand,
        Meadow,
        Wood,
        Rock
    }

    uint256 public constant PARCELS = 32; // parcels per side (1,024 parcels)
    uint256 public constant SUB = 8; // cells per parcel side
    uint256 public constant CELLS = 256; // cells per side

    int256 internal constant ONE = 65536; // fixed point 1.0
    int256 internal constant DIAG = 46341; // 0.70711 in fixed point
    int256 internal constant EDGE_START = 53740; // 0.82 in fixed point

    uint8 internal constant LAYER_ELEVATION = 0;
    uint8 internal constant LAYER_MOISTURE = 1;
    uint8 internal constant LAYER_WEATHER = 2;

    bytes32 public immutable seed;
    // Thresholds are calibrated offline for the seed (see scripts/calibrate.js)
    int256 public immutable waterT;
    int256 public immutable sandT;
    int256 public immutable rockT;
    int256 public immutable woodT;

    /// @notice Terrain at each parcel's center, one byte per parcel. Computed by this contract's
    ///         own constructor from the formula below, so it can't disagree with it.
    bytes public parcels;

    error OutOfBounds();

    constructor(bytes32 seed_, int256 waterT_, int256 sandT_, int256 rockT_, int256 woodT_) {
        seed = seed_;
        waterT = waterT_;
        sandT = sandT_;
        rockT = rockT_;
        woodT = woodT_;
        parcels = _cells(Block(SUB / 2, SUB / 2, PARCELS, PARCELS, SUB));
    }

    // ================================================================== single cells

    /// @notice Terrain of one cell, x and y in 0..255.
    function cellAt(uint256 x, uint256 y) public view returns (Cell) {
        int256 e = elevation(x, y);
        if (e < waterT) return Cell.Water;
        if (e < sandT) return Cell.Sand;
        if (e > rockT) return Cell.Rock;
        if (field(x, y, LAYER_MOISTURE) > woodT) return Cell.Wood;
        return Cell.Meadow;
    }

    /// @notice A parcel's terrain is the terrain at its center cell.
    function parcelCell(uint256 tokenId) public view returns (Cell) {
        return Cell(uint8(parcels[tokenId]));
    }

    /// @notice Sea plots can be owned but not farmed.
    function isSea(uint256 tokenId) external view returns (bool) {
        return parcelCell(tokenId) == Cell.Water;
    }

    function elevation(uint256 x, uint256 y) public view returns (int256) {
        return field(x, y, LAYER_ELEVATION) - falloff(x, y);
    }

    /// @notice Three octaves of Perlin noise, weighted 0.6 / 0.3 / 0.1.
    function field(uint256 x, uint256 y, uint8 layer) public view returns (int256) {
        return (6 * perlin(x, y, 72, layer) + 3 * perlin(x, y, 26, layer) + perlin(x, y, 9, layer)) / 10;
    }

    /// @notice One-dimensional weather noise, used to make season fronts arrive unevenly.
    function weather(uint256 x) external view returns (int256) {
        return perlin(x * 8 + 3, 11, 40, LAYER_WEATHER);
    }

    function perlin(uint256 x, uint256 y, uint256 spacing, uint8 layer) public view returns (int256) {
        unchecked {
            uint256 x0 = x / spacing;
            uint256 y0 = y / spacing;
            int256 fx = _frac(x, spacing);
            int256 fy = _frac(y, spacing);
            int256 u = _fade(fx);
            int256 a = _edge(layer, spacing, x0, y0, fx, fy, u);
            int256 b = _edge(layer, spacing, x0, y0 + 1, fx, fy - ONE, u);
            return _lerp(a, b, _fade(fy));
        }
    }

    /// @dev Dot products at two neighboring lattice corners, blended along x.
    function _edge(uint8 layer, uint256 spacing, uint256 ix, uint256 iy, int256 fx, int256 dy, int256 u)
        internal
        view
        returns (int256)
    {
        unchecked {
            (int256 gx0, int256 gy0) = _grad(layer, spacing, ix, iy);
            (int256 gx1, int256 gy1) = _grad(layer, spacing, ix + 1, iy);
            return _lerp((gx0 * fx + gy0 * dy) / ONE, (gx1 * (fx - ONE) + gy1 * dy) / ONE, u);
        }
    }

    /// @notice Distance-from-center falloff, plus a hard ramp near the border so the shore never
    ///         touches the edge of the map.
    function falloff(uint256 x, uint256 y) public pure returns (int256) {
        unchecked {
            int256 dx = int256(2 * x) - 255; // 2 * (x - center)
            int256 dy = int256(2 * y) - 255;
            int256 d2 = dx * dx + dy * dy; // == (distance / half-width)^2 in fixed point
            int256 ax = dx < 0 ? -dx : dx;
            int256 ay = dy < 0 ? -dy : dy;
            int256 e = (ax > ay ? ax : ay) * 256; // chebyshev distance in fixed point
            int256 edge = e > EDGE_START ? 4 * (e - EDGE_START) : int256(0);
            return (68 * d2) / 100 + edge;
        }
    }

    // ================================================================== blocks

    /// @dev One octave of one layer, prepared for a block of cells.
    struct Octave {
        uint256 nx; // lattice width
        int256[] gx; // gradient x per lattice point
        int256[] gy; // gradient y per lattice point
        uint256[] col; // lattice column per block column
        int256[] fx; // offset in the lattice square per block column
        int256[] u; // fade(fx)
        uint256[] row; // lattice row per block row
        int256[] fy;
        int256[] v; // fade(fy)
    }

    struct Block {
        uint256 x0;
        uint256 y0;
        uint256 w;
        uint256 h;
        uint256 step;
    }

    /// @notice Terrain for a w x h block of cells sampled every `step` cells from (x0, y0).
    ///         One byte per cell (a Cell value), row by row.
    function cells(uint256 x0, uint256 y0, uint256 w, uint256 h, uint256 step)
        external
        view
        returns (bytes memory)
    {
        return _cells(Block(x0, y0, w, h, step));
    }

    function _cells(Block memory b) internal view returns (bytes memory out) {
        if (b.x0 + (b.w - 1) * b.step >= CELLS || b.y0 + (b.h - 1) * b.step >= CELLS) revert OutOfBounds();
        Octave[3] memory el = _octaves(LAYER_ELEVATION, b);
        Octave[3] memory mo = _octaves(LAYER_MOISTURE, b);
        out = new bytes(b.w * b.h);
        for (uint256 j; j < b.h; ++j) {
            for (uint256 i; i < b.w; ++i) {
                out[j * b.w + i] = bytes1(uint8(_classify(el, mo, b, i, j)));
            }
        }
    }

    function _classify(Octave[3] memory el, Octave[3] memory mo, Block memory b, uint256 i, uint256 j)
        internal
        view
        returns (Cell)
    {
        int256 e = _blockField(el, i, j) - falloff(b.x0 + i * b.step, b.y0 + j * b.step);
        if (e < waterT) return Cell.Water;
        if (e < sandT) return Cell.Sand;
        if (e > rockT) return Cell.Rock;
        if (_blockField(mo, i, j) > woodT) return Cell.Wood;
        return Cell.Meadow;
    }

    function _octaves(uint8 layer, Block memory b) internal view returns (Octave[3] memory o) {
        o[0] = _octave(layer, 72, b);
        o[1] = _octave(layer, 26, b);
        o[2] = _octave(layer, 9, b);
    }

    function _octave(uint8 layer, uint256 s, Block memory b) internal view returns (Octave memory o) {
        uint256 ix0 = b.x0 / s;
        uint256 iy0 = b.y0 / s;
        o.nx = (b.x0 + (b.w - 1) * b.step) / s + 2 - ix0;
        uint256 ny = (b.y0 + (b.h - 1) * b.step) / s + 2 - iy0;
        o.gx = new int256[](o.nx * ny);
        o.gy = new int256[](o.nx * ny);
        for (uint256 j; j < ny; ++j) {
            for (uint256 i; i < o.nx; ++i) {
                (o.gx[j * o.nx + i], o.gy[j * o.nx + i]) = _grad(layer, s, ix0 + i, iy0 + j);
            }
        }
        (o.col, o.fx, o.u) = _axis(b.x0, b.w, b.step, s, ix0);
        (o.row, o.fy, o.v) = _axis(b.y0, b.h, b.step, s, iy0);
    }

    function _axis(uint256 start, uint256 n, uint256 step, uint256 s, uint256 i0)
        internal
        pure
        returns (uint256[] memory idx, int256[] memory f, int256[] memory fade)
    {
        idx = new uint256[](n);
        f = new int256[](n);
        fade = new int256[](n);
        for (uint256 k; k < n; ++k) {
            uint256 c = start + k * step;
            idx[k] = c / s - i0;
            f[k] = _frac(c, s);
            fade[k] = _fade(f[k]);
        }
    }

    function _blockField(Octave[3] memory o, uint256 i, uint256 j) internal pure returns (int256) {
        unchecked {
            return (6 * _blockSample(o[0], i, j) + 3 * _blockSample(o[1], i, j) + _blockSample(o[2], i, j)) / 10;
        }
    }

    /// @dev Same math as `perlin()`, reading the precomputed tables directly. Indices are always in
    ///      range because the tables were sized for this block, so bounds checks are skipped.
    ///      Octave layout in memory: nx, gx, gy, col, fx, u, row, fy, v (one word each).
    function _blockSample(Octave memory o, uint256 i, uint256 j) internal pure returns (int256 r) {
        assembly ("memory-safe") {
            let p // lattice index, then pointer to the corner's gx
            let fx
            let u
            {
                let off := shl(5, i)
                p := mload(add(add(mload(add(o, 0x60)), 0x20), off))
                fx := mload(add(add(mload(add(o, 0x80)), 0x20), off))
                u := mload(add(add(mload(add(o, 0xa0)), 0x20), off))
            }
            let fy
            let v
            {
                let off := shl(5, j)
                p := add(p, mul(mload(o), mload(add(add(mload(add(o, 0xc0)), 0x20), off))))
                fy := mload(add(add(mload(add(o, 0xe0)), 0x20), off))
                v := mload(add(add(mload(add(o, 0x100)), 0x20), off))
            }
            let d // distance from the gx table to the gy table
            {
                let gxData := add(mload(add(o, 0x20)), 0x20)
                d := sub(add(mload(add(o, 0x40)), 0x20), gxData)
                p := add(gxData, shl(5, p))
            }
            let a
            {
                let n00 := sdiv(add(mul(mload(p), fx), mul(mload(add(p, d)), fy)), 65536)
                let q := add(p, 0x20)
                let n10 := sdiv(add(mul(mload(q), sub(fx, 65536)), mul(mload(add(q, d)), fy)), 65536)
                a := add(n00, sdiv(mul(sub(n10, n00), u), 65536))
            }
            {
                let q := add(p, shl(5, mload(o)))
                let fy1 := sub(fy, 65536)
                let n01 := sdiv(add(mul(mload(q), fx), mul(mload(add(q, d)), fy1)), 65536)
                q := add(q, 0x20)
                let n11 := sdiv(add(mul(mload(q), sub(fx, 65536)), mul(mload(add(q, d)), fy1)), 65536)
                let b := add(n01, sdiv(mul(sub(n11, n01), u), 65536))
                r := add(a, sdiv(mul(sub(b, a), v), 65536))
            }
        }
    }

    // ================================================================== math

    function _grad(uint8 layer, uint256 spacing, uint256 ix, uint256 iy) internal view returns (int256, int256) {
        uint256 r = uint256(keccak256(abi.encodePacked(seed, layer, uint8(spacing), uint16(ix), uint16(iy)))) & 7;
        if (r == 0) return (ONE, 0);
        if (r == 1) return (-ONE, 0);
        if (r == 2) return (0, ONE);
        if (r == 3) return (0, -ONE);
        if (r == 4) return (DIAG, DIAG);
        if (r == 5) return (-DIAG, DIAG);
        if (r == 6) return (DIAG, -DIAG);
        return (-DIAG, -DIAG);
    }

    function _frac(uint256 c, uint256 s) internal pure returns (int256) {
        unchecked {
            return int256(((c % s) * uint256(ONE)) / s);
        }
    }

    function _lerp(int256 a, int256 b, int256 t) internal pure returns (int256) {
        unchecked {
            return a + ((b - a) * t) / ONE;
        }
    }

    /// @dev 6t^5 - 15t^4 + 10t^3
    function _fade(int256 t) internal pure returns (int256) {
        unchecked {
            int256 t3 = (((t * t) / ONE) * t) / ONE;
            return (t3 * ((t * (6 * t - 15 * ONE)) / ONE + 10 * ONE)) / ONE;
        }
    }
}
