// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC4906} from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

interface IFallowTerrain {
    function isSea(uint256 tokenId) external view returns (bool);
}

interface IFallowRenderer {
    function tokenURI(uint256 tokenId) external view returns (string memory);
}

/// @title Fallow
/// @notice 1,024 parcels on a 32x32 island. Owners tend their land once a day:
///         wild -> tilled -> sown -> harvest -> tilled -> ...
///         Land left untended for 30 days goes back to wild.
///         Consecutive days build a streak, and every tend adds loam (a hidden XP tally,
///         after Corruption(*s)'s insight). Longer streaks earn loam faster.
/// @dev    One storage slot per parcel. Decay and broken streaks are computed on read, so
///         nothing has to happen onchain for land to go wild.
contract Fallow is ERC721, Ownable, IERC4906 {
    enum Stage {
        Wild,
        Tilled,
        Sown,
        Harvest
    }

    struct Plot {
        uint8 stage; // stage as of the last tend
        uint32 lastDay; // UTC day of the last tend (0 = never)
        uint16 streak; // consecutive days, as of the last tend
        uint32 loam; // hidden XP, never decreases
    }

    uint256 public constant SUPPLY = 1024;
    uint256 public constant DECAY_DAYS = 30;
    uint256 public constant STREAK_STEP = 7; // +1 extra loam per tend for each full week of streak

    IFallowTerrain public immutable terrain;
    uint256 public immutable price;

    address public renderer;
    bool public rendererLocked;
    uint256 public totalMinted;

    mapping(uint256 => Plot) internal _plots;

    event Tended(uint256 indexed tokenId, Stage stage, uint256 streak, uint256 loam);
    event RendererSet(address indexed renderer);
    event RendererLockedForever();

    error OutOfRange();
    error WrongPrice();
    error NotPlotOwner();
    error SeaPlot();
    error AlreadyTendedToday();
    error RendererIsLocked();
    error WithdrawFailed();

    constructor(address terrain_, uint256 price_) ERC721("Fallow", "FALLOW") Ownable(msg.sender) {
        terrain = IFallowTerrain(terrain_);
        price = price_;
    }

    // ------------------------------------------------------------------ mint

    /// @notice Claim a parcel by coordinate: tokenId = y * 32 + x.
    function mint(uint256 tokenId) external payable {
        if (tokenId >= SUPPLY) revert OutOfRange();
        if (msg.value != price) revert WrongPrice();
        unchecked {
            ++totalMinted;
        }
        _mint(msg.sender, tokenId); // reverts if already minted
    }

    // ------------------------------------------------------------------ tend

    /// @notice The one verb. Once per UTC day, owner only, land parcels only.
    function tend(uint256 tokenId) external {
        if (ownerOf(tokenId) != msg.sender) revert NotPlotOwner();
        if (terrain.isSea(tokenId)) revert SeaPlot();

        Plot memory p = _plots[tokenId];
        uint32 day = uint32(block.timestamp / 1 days);
        if (p.lastDay >= day) revert AlreadyTendedToday();

        Stage current = _stageOn(p, day);
        Stage next = current == Stage.Harvest ? Stage.Tilled : Stage(uint8(current) + 1);
        uint16 streak = (p.lastDay != 0 && day == p.lastDay + 1) ? p.streak + 1 : 1;
        uint32 loam = p.loam + 1 + uint32(streak / STREAK_STEP);

        _plots[tokenId] = Plot(uint8(next), day, streak, loam);

        emit Tended(tokenId, next, streak, loam);
        emit MetadataUpdate(tokenId);
    }

    // ------------------------------------------------------------------ reads

    function today() public view returns (uint256) {
        return block.timestamp / 1 days;
    }

    /// @notice Current stage, with decay applied.
    function stageOf(uint256 tokenId) public view returns (Stage) {
        return _stageOn(_plots[tokenId], today());
    }

    /// @notice Current streak: 0 once a day has been missed, even before anyone touches storage.
    function streakOf(uint256 tokenId) public view returns (uint256) {
        Plot memory p = _plots[tokenId];
        if (p.lastDay == 0 || today() > uint256(p.lastDay) + 1) return 0;
        return p.streak;
    }

    function loamOf(uint256 tokenId) public view returns (uint256) {
        return _plots[tokenId].loam;
    }

    /// @notice Everything the renderer needs about one parcel.
    function plotOf(uint256 tokenId)
        external
        view
        returns (bool minted, Stage stage, uint256 streak, uint256 loam, uint256 lastDay)
    {
        Plot memory p = _plots[tokenId];
        return (_ownerOf(tokenId) != address(0), stageOf(tokenId), streakOf(tokenId), p.loam, p.lastDay);
    }

    /// @notice Current stages for a run of parcels, one byte each (for the map renderer).
    function stages(uint256 from, uint256 count) external view returns (bytes memory out) {
        if (from + count > SUPPLY) revert OutOfRange();
        uint256 day = today();
        out = new bytes(count);
        for (uint256 k; k < count; ++k) {
            out[k] = bytes1(uint8(_stageOn(_plots[from + k], day)));
        }
    }

    function _stageOn(Plot memory p, uint256 day) internal pure returns (Stage) {
        if (p.lastDay == 0 || day - p.lastDay > DECAY_DAYS) return Stage.Wild;
        return Stage(p.stage);
    }

    // ------------------------------------------------------------------ transfers

    /// @dev Moving land breaks its streak (Corruption(*s)-style destabilizing). Loam stays.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        from = super._update(to, tokenId, auth);
        if (from != address(0) && to != address(0) && _plots[tokenId].streak != 0) {
            _plots[tokenId].streak = 0;
            emit MetadataUpdate(tokenId);
        }
    }

    // ------------------------------------------------------------------ metadata

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        return IFallowRenderer(renderer).tokenURI(tokenId);
    }

    function setRenderer(address renderer_) external onlyOwner {
        if (rendererLocked) revert RendererIsLocked();
        renderer = renderer_;
        emit RendererSet(renderer_);
        emit BatchMetadataUpdate(0, SUPPLY - 1);
    }

    /// @notice One-way: freezes the art.
    function lockRenderer() external onlyOwner {
        rendererLocked = true;
        emit RendererLockedForever();
    }

    function withdraw() external onlyOwner {
        (bool ok,) = owner().call{value: address(this).balance}("");
        if (!ok) revert WithdrawFailed();
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, IERC165) returns (bool) {
        return interfaceId == bytes4(0x49064906) || super.supportsInterface(interfaceId);
    }
}
