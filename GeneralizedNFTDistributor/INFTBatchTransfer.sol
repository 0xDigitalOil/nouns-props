// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

/// @dev Interface for ERC721Like
interface ERC721Like {
    function transferFrom(
        address from,
        address to,
        uint256 tokenId
    ) external;

    function balanceOf(address owner) external view returns (uint256 balance);

    function ownerOf(uint256 tokenId) external view returns (address owner);

    function setApprovalForAll(address operator, bool approved) external;
    
    function totalSupply() external returns (uint256);

    function isApprovedForAll(address nftOwner, address operator) external view returns (bool);

}

/// @dev Interface for NounsVisionBatchTransfer
interface INFTBatchTransfer {
    function getStartId(ERC721Like nftAddress, uint256 suggStartId) external view returns (uint256 startId);

    function getStartIdAndBatchAmount(address receiver, uint256 suggStartId) external
        returns (uint256 startId, uint256 amount);

    function claimNFTs(uint256 startId, uint256 amount) external;

    function sendNFTs(ERC721Like nftAddress, uint256 startId, address recipient) external;

    function sendManyNFTs(ERC721Like nftAddress, uint256 startId, address[] calldata recipients) external;

    function allowanceFor(address nftAddress, address receiver) external view
        returns (uint256);

    function isApprovedAll(ERC721Like NFT) external view
        returns (bool approved);  
}