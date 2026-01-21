// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {PolicyNFT} from "../src/PolicyNFT.sol";

/**
 * @title PolicyNFTTest
 * @dev Tests for the PolicyNFT contract
 */
contract PolicyNFTTest is Test {
    PolicyNFT public nft;

    address public admin = address(this);
    address public minter = address(0x1);
    address public farmer1 = address(0x2);
    address public farmer2 = address(0x3);
    address public distributor1 = address(0x4);
    address public distributor2 = address(0x5);

    function setUp() public {
        nft = new PolicyNFT("MicroCrop Insurance Certificate", "mcINS");
        
        // Grant minter role
        nft.grantRole(nft.MINTER_ROLE(), minter);
    }

    // ============ Initialization Tests ============

    function test_Constructor() public view {
        assertEq(nft.name(), "MicroCrop Insurance Certificate");
        assertEq(nft.symbol(), "mcINS");
        assertTrue(nft.hasRole(nft.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(nft.hasRole(nft.ADMIN_ROLE(), admin));
    }

    // ============ Minting Tests ============

    function test_MintPolicy_Success() public {
        vm.prank(minter);
        uint256 tokenId = nft.mintPolicy(
            farmer1,
            1, // policyId
            distributor1,
            "Kenya Farmers Alliance",
            100_000e6, // sumInsured
            5_000e6, // premium
            block.timestamp,
            block.timestamp + 180 days,
            PolicyNFT.CoverageType.DROUGHT,
            "Kenya",
            12345
        );

        assertEq(tokenId, 1);
        assertEq(nft.ownerOf(tokenId), farmer1);
        assertEq(nft.balanceOf(farmer1), 1);
        assertTrue(nft.policyNFTExists(1));
    }

    function test_MintPolicy_StoresCertificateData() public {
        vm.prank(minter);
        nft.mintPolicy(
            farmer1,
            1,
            distributor1,
            "Kenya Farmers Alliance",
            100_000e6,
            5_000e6,
            block.timestamp,
            block.timestamp + 180 days,
            PolicyNFT.CoverageType.FLOOD,
            "Western Kenya",
            12345
        );

        PolicyNFT.PolicyCertificate memory cert = nft.getCertificate(1);

        assertEq(cert.policyId, 1);
        assertEq(cert.farmer, farmer1);
        assertEq(cert.distributor, distributor1);
        assertEq(cert.distributorName, "Kenya Farmers Alliance");
        assertEq(cert.sumInsured, 100_000e6);
        assertEq(cert.premium, 5_000e6);
        assertEq(uint256(cert.coverageType), uint256(PolicyNFT.CoverageType.FLOOD));
        assertEq(cert.region, "Western Kenya");
        assertEq(cert.plotId, 12345);
        assertTrue(cert.isActive);
    }

    function test_MintPolicy_TracksDistributorPolicies() public {
        vm.startPrank(minter);
        
        nft.mintPolicy(farmer1, 1, distributor1, "Dist1", 100_000e6, 5_000e6, 
            block.timestamp, block.timestamp + 180 days, PolicyNFT.CoverageType.DROUGHT, "Kenya", 1);
        
        nft.mintPolicy(farmer2, 2, distributor1, "Dist1", 50_000e6, 2_500e6,
            block.timestamp, block.timestamp + 90 days, PolicyNFT.CoverageType.FLOOD, "Tanzania", 2);
        
        vm.stopPrank();

        uint256[] memory distPolicies = nft.getDistributorPolicies(distributor1);
        assertEq(distPolicies.length, 2);
        assertEq(distPolicies[0], 1);
        assertEq(distPolicies[1], 2);
    }

    function test_MintPolicy_EmitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit PolicyNFT.PolicyNFTMinted(1, 1, farmer1, distributor1, 100_000e6);

        vm.prank(minter);
        nft.mintPolicy(
            farmer1, 1, distributor1, "Dist1", 100_000e6, 5_000e6,
            block.timestamp, block.timestamp + 180 days, 
            PolicyNFT.CoverageType.DROUGHT, "Kenya", 12345
        );
    }

    function test_MintPolicy_OnlyMinter() public {
        vm.prank(farmer1);
        vm.expectRevert();
        nft.mintPolicy(
            farmer1, 1, distributor1, "Dist1", 100_000e6, 5_000e6,
            block.timestamp, block.timestamp + 180 days,
            PolicyNFT.CoverageType.DROUGHT, "Kenya", 12345
        );
    }

    function test_MintPolicy_ZeroAddress_Reverts() public {
        vm.prank(minter);
        vm.expectRevert(PolicyNFT.ZeroAddress.selector);
        nft.mintPolicy(
            address(0), 1, distributor1, "Dist1", 100_000e6, 5_000e6,
            block.timestamp, block.timestamp + 180 days,
            PolicyNFT.CoverageType.DROUGHT, "Kenya", 12345
        );
    }

    function test_MintPolicy_DuplicatePolicy_Reverts() public {
        vm.startPrank(minter);
        
        nft.mintPolicy(farmer1, 1, distributor1, "Dist1", 100_000e6, 5_000e6,
            block.timestamp, block.timestamp + 180 days,
            PolicyNFT.CoverageType.DROUGHT, "Kenya", 12345);

        vm.expectRevert(abi.encodeWithSelector(PolicyNFT.PolicyAlreadyMinted.selector, 1));
        nft.mintPolicy(farmer2, 1, distributor1, "Dist1", 50_000e6, 2_500e6,
            block.timestamp, block.timestamp + 90 days,
            PolicyNFT.CoverageType.FLOOD, "Tanzania", 67890);
        
        vm.stopPrank();
    }

    // ============ Status Update Tests ============

    function test_UpdatePolicyStatus_Success() public {
        vm.startPrank(minter);
        
        nft.mintPolicy(farmer1, 1, distributor1, "Dist1", 100_000e6, 5_000e6,
            block.timestamp, block.timestamp + 180 days,
            PolicyNFT.CoverageType.DROUGHT, "Kenya", 12345);

        PolicyNFT.PolicyCertificate memory certBefore = nft.getCertificate(1);
        assertTrue(certBefore.isActive);

        nft.updatePolicyStatus(1, false);

        PolicyNFT.PolicyCertificate memory certAfter = nft.getCertificate(1);
        assertFalse(certAfter.isActive);
        
        vm.stopPrank();
    }

    function test_UpdatePolicyStatus_EmitsEvent() public {
        vm.startPrank(minter);
        
        nft.mintPolicy(farmer1, 1, distributor1, "Dist1", 100_000e6, 5_000e6,
            block.timestamp, block.timestamp + 180 days,
            PolicyNFT.CoverageType.DROUGHT, "Kenya", 12345);

        vm.expectEmit(true, false, false, true);
        emit PolicyNFT.PolicyStatusUpdated(1, false);
        nft.updatePolicyStatus(1, false);
        
        vm.stopPrank();
    }

    function test_UpdatePolicyStatus_NotFound_Reverts() public {
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(PolicyNFT.PolicyNotFound.selector, 999));
        nft.updatePolicyStatus(999, false);
    }

    // ============ Soulbound (Transfer Restriction) Tests ============

    function test_Transfer_WhileActive_Reverts() public {
        vm.prank(minter);
        nft.mintPolicy(farmer1, 1, distributor1, "Dist1", 100_000e6, 5_000e6,
            block.timestamp, block.timestamp + 180 days,
            PolicyNFT.CoverageType.DROUGHT, "Kenya", 12345);

        // Try to transfer while active
        vm.prank(farmer1);
        vm.expectRevert(abi.encodeWithSelector(PolicyNFT.TransferWhileActive.selector, 1));
        nft.transferFrom(farmer1, farmer2, 1);
    }

    function test_Transfer_AfterDeactivation_Succeeds() public {
        vm.prank(minter);
        nft.mintPolicy(farmer1, 1, distributor1, "Dist1", 100_000e6, 5_000e6,
            block.timestamp, block.timestamp + 180 days,
            PolicyNFT.CoverageType.DROUGHT, "Kenya", 12345);

        // Deactivate the policy
        vm.prank(minter);
        nft.updatePolicyStatus(1, false);

        // Now transfer should work
        vm.prank(farmer1);
        nft.transferFrom(farmer1, farmer2, 1);

        assertEq(nft.ownerOf(1), farmer2);
    }

    // ============ TokenURI / Metadata Tests ============

    function test_TokenURI_ReturnsBase64JSON() public {
        vm.prank(minter);
        nft.mintPolicy(farmer1, 1, distributor1, "Kenya Farmers Alliance", 100_000e6, 5_000e6,
            block.timestamp, block.timestamp + 180 days,
            PolicyNFT.CoverageType.DROUGHT, "Kenya", 12345);

        string memory uri = nft.tokenURI(1);
        
        // Should start with data:application/json;base64,
        assertTrue(bytes(uri).length > 29);
        
        // Check prefix
        bytes memory prefix = bytes("data:application/json;base64,");
        bytes memory uriBytes = bytes(uri);
        for (uint i = 0; i < prefix.length; i++) {
            assertEq(uriBytes[i], prefix[i]);
        }
    }

    function test_TokenURI_NonExistent_Reverts() public {
        vm.expectRevert();
        nft.tokenURI(999);
    }

    // ============ Enumerable Tests ============

    function test_Enumerable_TokenOfOwnerByIndex() public {
        vm.startPrank(minter);
        
        nft.mintPolicy(farmer1, 1, distributor1, "Dist1", 100_000e6, 5_000e6,
            block.timestamp, block.timestamp + 180 days,
            PolicyNFT.CoverageType.DROUGHT, "Kenya", 1);
        
        nft.mintPolicy(farmer1, 2, distributor1, "Dist1", 50_000e6, 2_500e6,
            block.timestamp, block.timestamp + 90 days,
            PolicyNFT.CoverageType.FLOOD, "Tanzania", 2);
        
        vm.stopPrank();

        assertEq(nft.balanceOf(farmer1), 2);
        assertEq(nft.tokenOfOwnerByIndex(farmer1, 0), 1);
        assertEq(nft.tokenOfOwnerByIndex(farmer1, 1), 2);
    }

    function test_Enumerable_TotalSupply() public {
        assertEq(nft.totalSupply(), 0);

        vm.startPrank(minter);
        
        nft.mintPolicy(farmer1, 1, distributor1, "Dist1", 100_000e6, 5_000e6,
            block.timestamp, block.timestamp + 180 days,
            PolicyNFT.CoverageType.DROUGHT, "Kenya", 1);
        
        assertEq(nft.totalSupply(), 1);

        nft.mintPolicy(farmer2, 2, distributor2, "Dist2", 50_000e6, 2_500e6,
            block.timestamp, block.timestamp + 90 days,
            PolicyNFT.CoverageType.FLOOD, "Tanzania", 2);
        
        assertEq(nft.totalSupply(), 2);
        
        vm.stopPrank();
    }

    // ============ Admin Tests ============

    function test_SetBaseExternalURI() public {
        nft.setBaseExternalURI("https://api.microcrop.io/nft/");
        assertEq(nft.baseExternalURI(), "https://api.microcrop.io/nft/");
    }

    function test_SetBaseExternalURI_OnlyAdmin() public {
        vm.prank(farmer1);
        vm.expectRevert();
        nft.setBaseExternalURI("https://fake.io/");
    }

    // ============ SupportsInterface Tests ============

    function test_SupportsInterface() public view {
        // ERC721
        assertTrue(nft.supportsInterface(0x80ac58cd));
        // ERC721Enumerable
        assertTrue(nft.supportsInterface(0x780e9d63));
        // AccessControl
        assertTrue(nft.supportsInterface(0x7965db0b));
        // ERC165
        assertTrue(nft.supportsInterface(0x01ffc9a7));
    }

    // ============ View Function Tests ============

    function test_PolicyNFTExists() public {
        assertFalse(nft.policyNFTExists(1));

        vm.prank(minter);
        nft.mintPolicy(farmer1, 1, distributor1, "Dist1", 100_000e6, 5_000e6,
            block.timestamp, block.timestamp + 180 days,
            PolicyNFT.CoverageType.DROUGHT, "Kenya", 12345);

        assertTrue(nft.policyNFTExists(1));
        assertFalse(nft.policyNFTExists(2));
    }

    // ============ Multiple Coverage Types ============

    function test_AllCoverageTypes() public {
        vm.startPrank(minter);

        nft.mintPolicy(farmer1, 1, distributor1, "Dist1", 100_000e6, 5_000e6,
            block.timestamp, block.timestamp + 180 days,
            PolicyNFT.CoverageType.DROUGHT, "Kenya", 1);

        nft.mintPolicy(farmer1, 2, distributor1, "Dist1", 100_000e6, 5_000e6,
            block.timestamp, block.timestamp + 180 days,
            PolicyNFT.CoverageType.FLOOD, "Kenya", 2);

        nft.mintPolicy(farmer1, 3, distributor1, "Dist1", 100_000e6, 5_000e6,
            block.timestamp, block.timestamp + 180 days,
            PolicyNFT.CoverageType.BOTH, "Kenya", 3);

        vm.stopPrank();

        assertEq(uint256(nft.getCertificate(1).coverageType), uint256(PolicyNFT.CoverageType.DROUGHT));
        assertEq(uint256(nft.getCertificate(2).coverageType), uint256(PolicyNFT.CoverageType.FLOOD));
        assertEq(uint256(nft.getCertificate(3).coverageType), uint256(PolicyNFT.CoverageType.BOTH));
    }
}
