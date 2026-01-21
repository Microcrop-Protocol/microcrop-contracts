// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {ERC721URIStorage} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

/**
 * @title PolicyNFT
 * @author MicroCrop Protocol
 * @notice ERC721 NFT representing insurance policy certificates for farmers
 * @dev Farmers receive an NFT when they purchase insurance from a distributor.
 *      The NFT contains on-chain metadata about the policy and serves as proof
 *      of coverage. The NFT is soulbound (non-transferable) while the policy is active.
 *
 * Features:
 *   - On-chain SVG artwork with policy details
 *   - Soulbound while policy is active (transfers unlock after expiry/claim)
 *   - Metadata includes coverage type, sum insured, dates, and distributor
 *   - Enumerable for easy portfolio querying
 *
 * Roles:
 *   - MINTER_ROLE: Can mint new policy NFTs (granted to PolicyManager/Backend)
 *   - ADMIN_ROLE: Can update contract settings
 */
contract PolicyNFT is ERC721, ERC721Enumerable, ERC721URIStorage, AccessControl {
    using Strings for uint256;
    using Strings for address;

    // ============ Structs ============

    /// @notice Policy certificate data stored on-chain
    struct PolicyCertificate {
        uint256 policyId;
        address farmer;
        address distributor;
        string distributorName;
        uint256 sumInsured;
        uint256 premium;
        uint256 startDate;
        uint256 endDate;
        CoverageType coverageType;
        string region;
        uint256 plotId;
        bool isActive;
    }

    /// @notice Coverage types matching PolicyManager
    enum CoverageType {
        DROUGHT,
        FLOOD,
        BOTH
    }

    // ============ Roles ============

    /// @notice Admin role for contract management
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Minter role for creating policy NFTs
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    // ============ Storage ============

    /// @notice Mapping from token ID to policy certificate
    mapping(uint256 => PolicyCertificate) public certificates;

    /// @notice Mapping from policy ID to token ID
    mapping(uint256 => uint256) public policyToToken;

    /// @notice Mapping from distributor address to their policies
    mapping(address => uint256[]) public distributorPolicies;

    /// @notice Base URI for external metadata (optional)
    string public baseExternalURI;

    // ============ Events ============

    /// @notice Emitted when a policy NFT is minted
    event PolicyNFTMinted(
        uint256 indexed tokenId,
        uint256 indexed policyId,
        address indexed farmer,
        address distributor,
        uint256 sumInsured
    );

    /// @notice Emitted when a policy status is updated
    event PolicyStatusUpdated(uint256 indexed tokenId, bool isActive);

    // ============ Errors ============

    error ZeroAddress();
    error PolicyAlreadyMinted(uint256 policyId);
    error TransferWhileActive(uint256 tokenId);
    error PolicyNotFound(uint256 policyId);

    // ============ Constructor ============

    /**
     * @notice Initialize the PolicyNFT contract
     * @param name_ Token name (e.g., "MicroCrop Insurance Certificate")
     * @param symbol_ Token symbol (e.g., "mcINS")
     */
    constructor(
        string memory name_,
        string memory symbol_
    ) ERC721(name_, symbol_) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
    }

    // ============ Minting ============

    /**
     * @notice Mint a policy NFT to a farmer
     * @dev Only callable by MINTER_ROLE (PolicyManager or Backend)
     * @param farmer Address of the farmer receiving the NFT
     * @param policyId Unique policy identifier
     * @param distributor Address of the insurance distributor
     * @param distributorName Human-readable distributor name
     * @param sumInsured Coverage amount in USDC (6 decimals)
     * @param premium Premium paid in USDC (6 decimals)
     * @param startDate Policy start timestamp
     * @param endDate Policy end timestamp
     * @param coverageType Type of coverage (DROUGHT, FLOOD, BOTH)
     * @param region Geographic region covered
     * @param plotId Off-chain plot reference
     * @return tokenId The minted token ID
     */
    function mintPolicy(
        address farmer,
        uint256 policyId,
        address distributor,
        string calldata distributorName,
        uint256 sumInsured,
        uint256 premium,
        uint256 startDate,
        uint256 endDate,
        CoverageType coverageType,
        string calldata region,
        uint256 plotId
    ) external onlyRole(MINTER_ROLE) returns (uint256 tokenId) {
        if (farmer == address(0)) revert ZeroAddress();
        if (policyToToken[policyId] != 0) revert PolicyAlreadyMinted(policyId);

        // Token ID = Policy ID for simplicity
        tokenId = policyId;

        // Store certificate data
        certificates[tokenId] = PolicyCertificate({
            policyId: policyId,
            farmer: farmer,
            distributor: distributor,
            distributorName: distributorName,
            sumInsured: sumInsured,
            premium: premium,
            startDate: startDate,
            endDate: endDate,
            coverageType: coverageType,
            region: region,
            plotId: plotId,
            isActive: true
        });

        policyToToken[policyId] = tokenId;
        distributorPolicies[distributor].push(tokenId);

        _safeMint(farmer, tokenId);

        emit PolicyNFTMinted(tokenId, policyId, farmer, distributor, sumInsured);
    }

    /**
     * @notice Update policy active status (called when policy expires or is claimed)
     * @dev Only callable by MINTER_ROLE
     * @param policyId The policy ID to update
     * @param isActive New active status
     */
    function updatePolicyStatus(
        uint256 policyId,
        bool isActive
    ) external onlyRole(MINTER_ROLE) {
        uint256 tokenId = policyToToken[policyId];
        if (tokenId == 0) revert PolicyNotFound(policyId);

        certificates[tokenId].isActive = isActive;
        emit PolicyStatusUpdated(tokenId, isActive);
    }

    // ============ View Functions ============

    /**
     * @notice Get all policy token IDs for a distributor
     * @param distributor Address of the distributor
     * @return Array of token IDs
     */
    function getDistributorPolicies(address distributor) external view returns (uint256[] memory) {
        return distributorPolicies[distributor];
    }

    /**
     * @notice Get policy certificate data
     * @param tokenId Token ID to query
     * @return certificate The policy certificate data
     */
    function getCertificate(uint256 tokenId) external view returns (PolicyCertificate memory) {
        return certificates[tokenId];
    }

    /**
     * @notice Check if a policy NFT exists
     * @param policyId The policy ID to check
     * @return exists Whether the NFT exists
     */
    function policyNFTExists(uint256 policyId) external view returns (bool) {
        return policyToToken[policyId] != 0;
    }

    // ============ Metadata ============

    /**
     * @notice Generate on-chain token URI with SVG artwork
     * @param tokenId Token ID to query
     * @return URI as base64 encoded JSON
     */
    function tokenURI(uint256 tokenId) public view override(ERC721, ERC721URIStorage) returns (string memory) {
        _requireOwned(tokenId);

        PolicyCertificate memory cert = certificates[tokenId];

        string memory svg = _generateSVG(cert);
        string memory json = _generateJSON(cert, svg);

        return string(abi.encodePacked(
            "data:application/json;base64,",
            Base64.encode(bytes(json))
        ));
    }

    /**
     * @notice Generate SVG artwork for the policy certificate
     */
    function _generateSVG(PolicyCertificate memory cert) internal pure returns (string memory) {
        string memory coverageStr = cert.coverageType == CoverageType.DROUGHT ? "Drought" :
                                    cert.coverageType == CoverageType.FLOOD ? "Flood" : "Drought + Flood";

        string memory statusColor = cert.isActive ? "#22c55e" : "#6b7280";
        string memory statusText = cert.isActive ? "ACTIVE" : "INACTIVE";

        return string(abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" width="400" height="500" viewBox="0 0 400 500">',
            '<defs>',
            '<linearGradient id="bg" x1="0%" y1="0%" x2="100%" y2="100%">',
            '<stop offset="0%" style="stop-color:#1e3a5f"/>',
            '<stop offset="100%" style="stop-color:#0d1b2a"/>',
            '</linearGradient>',
            '</defs>',
            '<rect width="400" height="500" fill="url(#bg)" rx="20"/>',
            '<rect x="15" y="15" width="370" height="470" fill="none" stroke="#3b82f6" stroke-width="2" rx="15"/>',
            _generateSVGContent(cert, coverageStr, statusColor, statusText),
            '</svg>'
        ));
    }

    function _generateSVGContent(
        PolicyCertificate memory cert,
        string memory coverageStr,
        string memory statusColor,
        string memory statusText
    ) internal pure returns (string memory) {
        return string(abi.encodePacked(
            // Header
            '<text x="200" y="50" font-family="Arial, sans-serif" font-size="24" fill="#ffffff" text-anchor="middle" font-weight="bold">MicroCrop Insurance</text>',
            '<text x="200" y="75" font-family="Arial, sans-serif" font-size="14" fill="#94a3b8" text-anchor="middle">Policy Certificate</text>',
            // Status badge
            '<rect x="150" y="90" width="100" height="25" fill="', statusColor, '" rx="12"/>',
            '<text x="200" y="108" font-family="Arial, sans-serif" font-size="12" fill="#ffffff" text-anchor="middle" font-weight="bold">', statusText, '</text>',
            // Policy details
            '<text x="30" y="150" font-family="Arial, sans-serif" font-size="12" fill="#94a3b8">Policy ID</text>',
            '<text x="30" y="170" font-family="Arial, sans-serif" font-size="16" fill="#ffffff">#', cert.policyId.toString(), '</text>',
            '<text x="30" y="210" font-family="Arial, sans-serif" font-size="12" fill="#94a3b8">Coverage Type</text>',
            '<text x="30" y="230" font-family="Arial, sans-serif" font-size="16" fill="#ffffff">', coverageStr, '</text>',
            '<text x="30" y="270" font-family="Arial, sans-serif" font-size="12" fill="#94a3b8">Sum Insured</text>',
            '<text x="30" y="290" font-family="Arial, sans-serif" font-size="16" fill="#22c55e">$', _formatUSDC(cert.sumInsured), '</text>',
            '<text x="30" y="330" font-family="Arial, sans-serif" font-size="12" fill="#94a3b8">Region</text>',
            '<text x="30" y="350" font-family="Arial, sans-serif" font-size="16" fill="#ffffff">', cert.region, '</text>',
            '<text x="30" y="390" font-family="Arial, sans-serif" font-size="12" fill="#94a3b8">Distributor</text>',
            '<text x="30" y="410" font-family="Arial, sans-serif" font-size="16" fill="#ffffff">', cert.distributorName, '</text>',
            // Footer
            '<line x1="30" y1="450" x2="370" y2="450" stroke="#3b82f6" stroke-width="1"/>',
            '<text x="200" y="475" font-family="Arial, sans-serif" font-size="10" fill="#64748b" text-anchor="middle">Powered by MicroCrop Protocol</text>'
        ));
    }

    /**
     * @notice Format USDC amount for display (6 decimals to human readable)
     */
    function _formatUSDC(uint256 amount) internal pure returns (string memory) {
        uint256 whole = amount / 1e6;
        return whole.toString();
    }

    /**
     * @notice Generate JSON metadata
     */
    function _generateJSON(PolicyCertificate memory cert, string memory svg) internal pure returns (string memory) {
        string memory coverageStr = cert.coverageType == CoverageType.DROUGHT ? "Drought" :
                                    cert.coverageType == CoverageType.FLOOD ? "Flood" : "Drought + Flood";

        return string(abi.encodePacked(
            '{"name":"MicroCrop Policy #', cert.policyId.toString(), '",',
            '"description":"Insurance policy certificate for crop coverage in ', cert.region, '",',
            '"image":"data:image/svg+xml;base64,', Base64.encode(bytes(svg)), '",',
            '"attributes":[',
            '{"trait_type":"Policy ID","value":"', cert.policyId.toString(), '"},',
            '{"trait_type":"Coverage Type","value":"', coverageStr, '"},',
            '{"trait_type":"Sum Insured","value":"$', _formatUSDC(cert.sumInsured), '"},',
            '{"trait_type":"Premium","value":"$', _formatUSDC(cert.premium), '"},',
            '{"trait_type":"Region","value":"', cert.region, '"},',
            '{"trait_type":"Distributor","value":"', cert.distributorName, '"},',
            '{"trait_type":"Status","value":"', cert.isActive ? "Active" : "Inactive", '"},',
            '{"trait_type":"Plot ID","value":"', cert.plotId.toString(), '"}',
            ']}'
        ));
    }

    // ============ Transfer Restrictions ============

    /**
     * @notice Override transfer to enforce soulbound behavior while active
     * @dev Transfers are only allowed after policy expires or is claimed
     */
    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal override(ERC721, ERC721Enumerable) returns (address) {
        address from = _ownerOf(tokenId);
        
        // Allow minting (from == address(0)) and burning (to == address(0))
        // Block transfers while policy is active
        if (from != address(0) && to != address(0)) {
            if (certificates[tokenId].isActive) {
                revert TransferWhileActive(tokenId);
            }
        }

        return super._update(to, tokenId, auth);
    }

    // ============ Admin Functions ============

    /**
     * @notice Set base external URI for off-chain metadata
     * @param uri New base URI
     */
    function setBaseExternalURI(string calldata uri) external onlyRole(ADMIN_ROLE) {
        baseExternalURI = uri;
    }

    // ============ Required Overrides ============

    function _increaseBalance(address account, uint128 value) internal override(ERC721, ERC721Enumerable) {
        super._increaseBalance(account, value);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC721Enumerable, ERC721URIStorage, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
