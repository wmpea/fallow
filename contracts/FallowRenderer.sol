// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {FallowTerrain} from "./FallowTerrain.sol";

interface IFallowPlots {
    function plotOf(uint256 tokenId)
        external
        view
        returns (bool minted, uint8 stage, uint256 streak, uint256 loam, uint256 lastDay);
    function stages(uint256 from, uint256 count) external view returns (bytes memory);
    function today() external view returns (uint256);
}

/// @title FallowRenderer
/// @notice Draws Fallow entirely onchain as text-glyph SVG.
///         - A token shows its parcel lit and its eight neighbors dimmed (24x24 glyphs).
///         - The full map shows one glyph per parcel (32x32).
///         - Each season has a 4-color palette. Seasons change on Mar 1 / Jun 1 / Sep 1 / Dec 1,
///           sweeping north to south about 1.5 parcel rows a day along an uneven front.
/// @dev    Swappable from the game contract until it is locked. Stateless.
///         Glyphs are emitted one <text> per row and color, with a positioned <tspan> per glyph
///         (per-character x lists aren't supported by every rasterizer).
contract FallowRenderer {
    using Strings for uint256;

    uint256 internal constant P = 32; // parcels per side
    uint256 internal constant S = 8; // cells per parcel side
    int256 internal constant ONE = 65536;
    uint256 internal constant LOAM_MAX = 400;
    int256 internal constant JITTER = 32; // how far (in cell rows) weather can push the season front

    // hash tags
    uint8 internal constant TAG_ORIENT = 1;
    uint8 internal constant TAG_WILD = 2;
    uint8 internal constant TAG_DITHER = 3;
    uint8 internal constant TAG_RIPE = 4;

    // color keys
    uint8 internal constant INK = 0;
    uint8 internal constant WATER = 1;
    uint8 internal constant ACCENT = 2;
    uint8 internal constant NONE = 255;

    // stages (mirrors Fallow.Stage)
    uint8 internal constant WILD = 0;
    uint8 internal constant TILLED = 1;
    uint8 internal constant SOWN = 2;
    uint8 internal constant HARVEST = 3;

    // terrain (mirrors FallowTerrain.Cell)
    uint8 internal constant C_WATER = 0;
    uint8 internal constant C_SAND = 1;
    uint8 internal constant C_WOOD = 3;
    uint8 internal constant C_ROCK = 4;

    IFallowPlots public immutable fallow;
    FallowTerrain public immutable terrain;

    constructor(address fallow_, address terrain_) {
        fallow = IFallowPlots(fallow_);
        terrain = FallowTerrain(terrain_);
    }

    // ================================================================== metadata

    function tokenURI(uint256 tokenId) external view returns (string memory) {
        uint256 day = fallow.today();
        string memory json = string.concat(
            '{"name":"Fallow ',
            _coord(tokenId % P, tokenId / P),
            '","description":"A parcel of Fallow, an island of 1,024 plots computed entirely onchain. Tend it once a day or it goes back to wild.","image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(tokenSvg(tokenId, day))),
            '","attributes":',
            _attributes(tokenId, day),
            "}"
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    function _attributes(uint256 tokenId, uint256 day) internal view returns (string memory) {
        (, uint8 stage, uint256 streak, uint256 loam,) = fallow.plotOf(tokenId);
        uint256 px = tokenId % P;
        uint256 py = tokenId / P;
        Weather memory w = _weather(day, px, 1);
        return string.concat(
            '[{"trait_type":"Terrain","value":"',
            _cellName(uint8(terrain.parcelCell(tokenId))),
            '"},{"trait_type":"Stage","value":"',
            _stageName(stage),
            '"},{"trait_type":"Rows","value":"',
            _orientName(_orient(w.seed, px, py)),
            '"},{"trait_type":"Season","value":"',
            _seasonName(_seasonAt(w, px * S + S / 2, py * S + S / 2, px)),
            '"},{"display_type":"number","trait_type":"Loam","value":',
            loam.toString(),
            '},{"display_type":"number","trait_type":"Streak","value":',
            streak.toString(),
            "}]"
        );
    }

    // ================================================================== token view

    struct View {
        uint256 ox; // center parcel x
        uint256 oy; // center parcel y
        uint8[9] stage;
        uint256[9] loam;
        uint8[9] orient;
        bool[9] onMap;
        Weather w;
        bytes cells; // terrain for the clipped 3x3 block
        uint256 cx0; // first cell column of the block
        uint256 cy0; // first cell row of the block
        uint256 cw; // block width in cells
        string[] colX; // opening <tspan x="..."> for each glyph column
        uint8 base; // season at the center of the parcel
    }

    /// @notice The token image on a given UTC day (pass fallow.today() for now).
    function tokenSvg(uint256 tokenId, uint256 day) public view returns (string memory) {
        View memory v = _view(tokenId, day);
        string memory bg;
        string memory dim;
        string memory lit;
        for (uint256 gj; gj < 3 * S; ++gj) {
            bg = string.concat(bg, _rowBackground(v, gj));
            for (uint256 seg; seg < 3; ++seg) {
                if (gj / S == 1 && seg == 1) lit = string.concat(lit, _segment(v, gj, seg));
                else dim = string.concat(dim, _segment(v, gj, seg));
            }
        }
        string memory b = uint256(v.base).toString();
        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 720 720" width="720" height="720">',
            _style(17),
            '<rect width="720" height="720" class="b',
            b,
            '"/>',
            bg,
            '<g class="n">',
            dim,
            "</g>",
            lit,
            '<path d="M251 259V243H267M453 243H469V259M469 445V461H453M267 461H251V445" fill="none" stroke-width="2" class="k',
            b,
            '"/>',
            _caption(v),
            "</svg>"
        );
    }

    function _view(uint256 tokenId, uint256 day) internal view returns (View memory v) {
        v.ox = tokenId % P;
        v.oy = tokenId / P;
        v.w = _weather(day, v.ox > 0 ? v.ox - 1 : 0, 3);
        for (uint256 n; n < 9; ++n) {
            int256 px = int256(v.ox) + int256(n % 3) - 1;
            int256 py = int256(v.oy) + int256(n / 3) - 1;
            if (px < 0 || py < 0 || px >= int256(P) || py >= int256(P)) continue;
            v.onMap[n] = true;
            (, v.stage[n],, v.loam[n],) = fallow.plotOf(uint256(py) * P + uint256(px));
            v.orient[n] = _orient(v.w.seed, uint256(px), uint256(py));
        }
        v.cx0 = v.ox > 0 ? (v.ox - 1) * S : 0;
        v.cy0 = v.oy > 0 ? (v.oy - 1) * S : 0;
        uint256 cx1 = v.ox < P - 1 ? (v.ox + 2) * S - 1 : P * S - 1;
        uint256 cy1 = v.oy < P - 1 ? (v.oy + 2) * S - 1 : P * S - 1;
        v.cw = cx1 - v.cx0 + 1;
        v.cells = terrain.cells(v.cx0, v.cy0, v.cw, cy1 - v.cy0 + 1, 1);
        v.colX = new string[](3 * S);
        for (uint256 gi; gi < 3 * S; ++gi) {
            v.colX[gi] = string.concat('<tspan x="', (61 + 26 * gi).toString(), '">');
        }
        v.base = _seasonAt(v.w, v.ox * S + S / 2, v.oy * S + S / 2, v.ox);
    }

    /// @dev Eight glyphs of one row of one parcel, grouped into one <text> per color and season.
    function _segment(View memory v, uint256 gj, uint256 seg) internal view returns (string memory) {
        Bucket memory k;
        k.cur = v.onMap[(gj / S) * 3 + seg] ? v.w.cur : v.base;
        for (uint256 c; c < S; ++c) {
            _segmentCell(v, k, gj, seg, c);
        }
        return _flush(k, (59 + 26 * gj).toString());
    }

    function _segmentCell(View memory v, Bucket memory k, uint256 gj, uint256 seg, uint256 c) internal view {
        if (!v.onMap[(gj / S) * 3 + seg]) {
            _add(k, v.colX[seg * S + c], "~", WATER, v.base); // open sea beyond the map
            return;
        }
        (string memory g, uint8 key, uint8 season) = _cellInView(v, gj, seg, c);
        if (key != NONE) _add(k, v.colX[seg * S + c], g, key, season);
    }

    function _cellInView(View memory v, uint256 gj, uint256 seg, uint256 c)
        internal
        view
        returns (string memory g, uint8 key, uint8 season)
    {
        uint256 fx = (v.ox + seg - 1) * S + c;
        uint256 fy = (v.oy + gj / S - 1) * S + gj % S;
        (g, key) = _cellGlyph(v, (gj / S) * 3 + seg, fx, fy);
        if (key != NONE) season = _seasonAt(v.w, fx, fy, v.ox + seg - 1);
    }

    /// @dev Background runs for cells whose season differs from the base season.
    function _rowBackground(View memory v, uint256 gj) internal view returns (string memory bg) {
        uint256 band = gj / S;
        if (!v.onMap[band * 3 + 1]) return "";
        uint256 fy = (v.oy + band - 1) * S + gj % S;
        uint256 runStart;
        uint8 run = v.base;
        for (uint256 gi; gi <= 3 * S; ++gi) {
            uint8 season = v.base;
            if (gi < 3 * S && v.onMap[band * 3 + gi / S]) {
                season = _seasonAt(v.w, (v.ox + gi / S - 1) * S + gi % S, fy, v.ox + gi / S - 1);
            }
            if (gi == 3 * S || season != run) {
                if (run != v.base) bg = string.concat(bg, _rect(48 + 26 * runStart, 40 + 26 * gj, 26 * (gi - runStart), 26, run));
                runStart = gi;
                run = season;
            }
        }
    }

    function _cellGlyph(View memory v, uint256 n, uint256 fx, uint256 fy)
        internal
        pure
        returns (string memory, uint8)
    {
        uint8 c = uint8(v.cells[(fy - v.cy0) * v.cw + (fx - v.cx0)]);
        if (c == C_WATER) return ("~", WATER);
        if (c == C_SAND) return (".", INK);
        if (c == C_ROCK) return ("^", INK);
        if (c == C_WOOD) return (unicode"♣", INK);
        return _meadowGlyph(v.w.seed, v.stage[n], v.orient[n], v.loam[n], fx, fy);
    }

    function _meadowGlyph(bytes32 seed, uint8 stage, uint8 orient, uint256 loam, uint256 fx, uint256 fy)
        internal
        pure
        returns (string memory, uint8)
    {
        if (stage == WILD) {
            uint256 pick = _rand(seed, TAG_WILD, fx, fy) % 9;
            if (pick == 0 || pick == 6) return ('"', INK);
            if (pick == 1 || pick == 7) return (",", INK);
            if (pick == 2 || pick == 8) return ("'", INK);
            if (pick == 3) return (";", INK);
            return ("", NONE);
        }
        uint256 i = fx % S;
        uint256 j = fy % S;
        uint256 line = orient == 0 ? j : orient == 1 ? i : i + j;
        if (line % 2 == 1) return ("", NONE); // bare soil between rows
        if (stage == TILLED) return (_tillGlyph(orient), INK);
        if (stage == SOWN) return (":", ACCENT);
        // harvest ripens unevenly; loam decides how much comes in ripe (per mille)
        uint256 ripe = 250 + (700 * (loam > LOAM_MAX ? LOAM_MAX : loam)) / LOAM_MAX;
        uint256 r = _rand(seed, TAG_RIPE, fx, fy) % 1000;
        if (r < ripe) return (unicode"ψ", ACCENT);
        if (r < ripe + ((1000 - ripe) * 6) / 10) return ("|", ACCENT);
        return ("", NONE);
    }

    function _caption(View memory v) internal pure returns (string memory) {
        string memory s = uint256(v.base).toString();
        return string.concat(
            '<text x="48" y="698" class="c i',
            s,
            '">FALLOW ',
            _coord(v.ox, v.oy),
            '</text><text x="672" y="698" class="c e i',
            s,
            '">',
            _stageCaps(v.stage[4]),
            "</text>"
        );
    }

    // ================================================================== map view

    /// @notice The whole island, one glyph per parcel, on a given UTC day.
    function mapSvg(uint256 day) external view returns (string memory) {
        Map memory m;
        m.w = _weather(day, 0, P);
        m.cells = terrain.parcels();
        m.stages = fallow.stages(0, P * P);
        m.colX = new string[](P);
        for (uint256 px; px < P; ++px) {
            m.colX[px] = string.concat('<tspan x="', (10 + 20 * px).toString(), '">');
        }
        string memory bg;
        string memory body;
        for (uint256 py; py < P; ++py) {
            (string memory b, string memory t) = _mapRow(m, py);
            bg = string.concat(bg, b);
            body = string.concat(body, t);
        }
        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 640 640" width="640" height="640">',
            _style(14),
            bg,
            body,
            "</svg>"
        );
    }

    struct Map {
        Weather w;
        bytes cells; // terrain at each parcel center
        bytes stages; // current stage of each parcel
        string[] colX;
    }

    function _mapRow(Map memory m, uint256 py) internal view returns (string memory bg, string memory body) {
        Bucket memory k;
        k.cur = m.w.cur;
        uint256 runStart;
        uint8 run = 255;
        for (uint256 px; px <= P; ++px) {
            uint8 season = px < P ? _mapCell(m, k, px, py) : 255;
            if (season != run) {
                if (run != 255) bg = string.concat(bg, _rect(20 * runStart, 20 * py, 20 * (px - runStart), 20, run));
                runStart = px;
                run = season;
            }
        }
        body = _flush(k, (15 + 20 * py).toString());
    }

    function _mapCell(Map memory m, Bucket memory k, uint256 px, uint256 py) internal view returns (uint8 season) {
        season = _seasonAt(m.w, px * S + S / 2, py * S + S / 2, px);
        (string memory g, uint8 key) = _parcelGlyph(m, px, py);
        _add(k, m.colX[px], g, key, season);
    }

    function _parcelGlyph(Map memory m, uint256 px, uint256 py) internal pure returns (string memory, uint8) {
        uint8 c = uint8(m.cells[py * P + px]);
        if (c == C_WATER) return ("~", WATER);
        if (c == C_SAND) return (".", INK);
        if (c == C_ROCK) return ("^", INK);
        if (c == C_WOOD) return (unicode"♣", INK);
        uint8 stage = uint8(m.stages[py * P + px]);
        if (stage == WILD) return ('"', INK);
        if (stage == SOWN) return (":", ACCENT);
        if (stage == HARVEST) return (unicode"ψ", ACCENT);
        return (_tillGlyph(_orient(m.w.seed, px, py)), INK);
    }

    // ================================================================== glyph buckets

    /// @dev Glyphs collected per (color, season): index = key * 2 + (season == current ? 0 : 1).
    struct Bucket {
        string[6] glyphs; // positioned <tspan>s
        uint8[6] season;
        uint8 cur; // the current season goes in the even slots
    }

    function _add(Bucket memory k, string memory x, string memory g, uint8 key, uint8 season) internal pure {
        uint256 b = uint256(key) * 2 + (season == k.cur ? 0 : 1);
        k.glyphs[b] = string.concat(k.glyphs[b], x, g, "</tspan>");
        k.season[b] = season;
    }

    function _flush(Bucket memory k, string memory y) internal pure returns (string memory out) {
        for (uint256 b; b < 6; ++b) {
            if (bytes(k.glyphs[b]).length == 0) continue;
            out = string.concat(
                out,
                '<text y="',
                y,
                '" class="',
                b < 2 ? "i" : b < 4 ? "w" : "a",
                uint256(k.season[b]).toString(),
                '">',
                k.glyphs[b],
                "</text>"
            );
        }
    }

    function _rect(uint256 x, uint256 y, uint256 width, uint256 height, uint8 season)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            '<rect x="',
            x.toString(),
            '" y="',
            y.toString(),
            '" width="',
            width.toString(),
            '" height="',
            height.toString(),
            '" class="b',
            uint256(season).toString(),
            '"/>'
        );
    }

    // ================================================================== seasons

    struct Weather {
        uint8 cur; // current season: 0 spring, 1 summer, 2 autumn, 3 winter
        uint8 prev;
        int256 front; // front position in cell rows, before jitter
        uint256 firstColumn; // parcel column of jitter[0]
        int256[] jitter; // front offset per parcel column, in cell rows
        bytes32 seed; // terrain seed, for local hashing
    }

    /// @notice Season and days since it began, for a UTC day number.
    /// @dev Civil-from-days (H. Hinnant), with the year counted from March 1st so seasons are
    ///      just quarters of it: Mar-May, Jun-Aug, Sep-Nov, Dec-Feb.
    function seasonOn(uint256 day) public pure returns (uint8 season, uint256 daysIn) {
        uint256 doe = (day + 719468) % 146097;
        uint256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // 0 = March 1st
        season = uint8(((5 * doy + 2) / 153) / 3);
        daysIn = doy - (153 * (uint256(season) * 3) + 2) / 5;
    }

    function _weather(uint256 day, uint256 firstColumn, uint256 count) internal view returns (Weather memory w) {
        (uint8 season, uint256 daysIn) = seasonOn(day);
        w.cur = season;
        w.prev = (season + 3) % 4;
        w.front = int256(daysIn) * 12; // 1.5 parcel rows (12 cell rows) a day
        w.firstColumn = firstColumn;
        w.jitter = new int256[](count);
        w.seed = terrain.seed();
        for (uint256 k; k < count && firstColumn + k < P; ++k) {
            w.jitter[k] = (terrain.weather(firstColumn + k) * JITTER) / ONE;
        }
    }

    /// @dev North of the front: new season. South: old season. A 24-row band at the front is dithered.
    function _seasonAt(Weather memory w, uint256 fx, uint256 fy, uint256 px) internal view returns (uint8) {
        int256 j;
        if (px >= w.firstColumn && px < w.firstColumn + w.jitter.length) j = w.jitter[px - w.firstColumn];
        else j = (terrain.weather(px) * JITTER) / ONE;
        int256 front = w.front + j;
        int256 y = int256(fy);
        if (y < front - 12) return w.cur;
        if (y > front + 12) return w.prev;
        uint256 r = _rand(w.seed, TAG_DITHER, fx, fy) % 24;
        return int256(r) < front + 12 - y ? w.cur : w.prev;
    }

    // ================================================================== helpers

    function _orient(bytes32 seed, uint256 px, uint256 py) internal pure returns (uint8) {
        return uint8(_rand(seed, TAG_ORIENT, px, py) & 3);
    }

    /// @dev Seeded hash for row direction, wild grass, ripeness and the dithered season front.
    function _rand(bytes32 seed, uint8 tag, uint256 a, uint256 b) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(seed, tag, uint16(a), uint16(b))));
    }

    function _tillGlyph(uint8 o) internal pure returns (string memory) {
        return o == 0 ? "=" : o == 1 ? "|" : o == 2 ? "/" : "\\";
    }

    /// @dev Four palettes: bg / ink / water / accent, for spring, summer, autumn, winter.
    function _style(uint256 fontSize) internal pure returns (string memory) {
        return string.concat(
            "<style>text{font-family:ui-monospace,Menlo,Consolas,monospace;font-size:",
            fontSize.toString(),
            "px;text-anchor:middle}rect{shape-rendering:crispEdges}.n{opacity:.32}.c{font-size:13px;letter-spacing:.12em;text-anchor:start}.e{text-anchor:end}",
            ".b0{fill:#EDEFE4}.i0{fill:#64785A}.w0{fill:#3F6F96}.a0{fill:#B8496E}.k0{stroke:#B8496E}",
            ".b1{fill:#F2E6C4}.i1{fill:#857338}.w1{fill:#2D6D8C}.a1{fill:#BE431B}.k1{stroke:#BE431B}",
            ".b2{fill:#17140F}.i2{fill:#8F7E5E}.w2{fill:#4C7590}.a2{fill:#E3A63F}.k2{stroke:#E3A63F}",
            ".b3{fill:#E6E9EC}.i3{fill:#7A8692}.w3{fill:#4A6A82}.a3{fill:#2B3440}.k3{stroke:#2B3440}</style>"
        );
    }

    function _coord(uint256 px, uint256 py) internal pure returns (string memory) {
        return string.concat(px < 10 ? "0" : "", px.toString(), ",", py < 10 ? "0" : "", py.toString());
    }

    function _stageName(uint8 s) internal pure returns (string memory) {
        return s == WILD ? "Wild" : s == TILLED ? "Tilled" : s == SOWN ? "Sown" : "Harvest";
    }

    function _stageCaps(uint8 s) internal pure returns (string memory) {
        return s == WILD ? "WILD" : s == TILLED ? "TILLED" : s == SOWN ? "SOWN" : "HARVEST";
    }

    function _seasonName(uint8 s) internal pure returns (string memory) {
        return s == 0 ? "Spring" : s == 1 ? "Summer" : s == 2 ? "Autumn" : "Winter";
    }

    function _orientName(uint8 o) internal pure returns (string memory) {
        return o == 0 ? "East-West" : o == 1 ? "North-South" : o == 2 ? "Diagonal /" : "Diagonal \\\\";
    }

    function _cellName(uint8 c) internal pure returns (string memory) {
        if (c == C_WATER) return "Sea";
        if (c == C_SAND) return "Shore";
        if (c == C_WOOD) return "Wood";
        if (c == C_ROCK) return "Rock";
        return "Meadow";
    }
}
