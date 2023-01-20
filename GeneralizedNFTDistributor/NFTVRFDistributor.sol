// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "./VRFv2Consumer.sol";
import "./INFTBatchTransfer.sol";
import "./INounsDAOProxy.sol";

// crafted with ❤️ by @0xDigitalOil for Nouns DAO ⌐◨-◨
contract NFTVRFDistributor is VRFv2Consumer {
    
    /**
    ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
      EVENTS
    ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
    **/

    /// @dev Event log for when a round is requested
    /// @param requestId request id generated by Chainlink
    /// @param nftAddress address of the NFT collection being distributed
    event RoundRequested(uint256 requestId, address nftAddress);

    /// @dev Event log for when a round is fulfilled
    /// @param nftAddress address of the NFT collection being distributed
    /// @param roundId id of the claimRound
    /// @param numberWon number of NFTs claimable in this round
    /// @param randomness block at which the claim ends    
    event RoundFulfilled(address nftAddress, uint8 roundId, uint8 numberWon, uint152 randomness);

    /// @dev Event log for when a round is requested
    /// @param nftAddress address of the NFT collection being distributed
    /// @param roundId id of the claimRound
    /// @param index claimed NFTs index (in the claim round's context)
    /// @param winner address that claimed the NFTs
    event NFTClaimed(address nftAddress, uint8 roundId, uint8 index, address winner);    


    /**
    ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
      CONSTANTS & IMMUTABLE
    ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
    **/

    ERC721Like public constant NOUNS_TOKEN =
        ERC721Like(0x312a72C4Fc5E4Ea9D9ae0d21739130B9CF2758aC);       

    INounsDAOProxy public constant NOUNS_DAO_PROXY = 
        INounsDAOProxy(0x7A1BF7E1f799151Fb60eCdb9290e907c73e6F67C);

    INFTBatchTransfer public immutable NFT_BATCH_TRANSFER;       
    
    uint256 public constant CLAIM_WINDOW = 108_000; // 15 days in blocks

 
    /**
    ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
      STRUCTS & STORAGE VARIABLES
    ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
    **/

    struct ClaimRound {
        uint8 id;
        uint8 numberWon;
        uint8 numberClaimed;
        uint16 nounSupply;
        uint32 startBlock;
        uint32 endBlock;
        uint152 randomness;
        uint256 claimedBitmap;
    } 

    mapping (address => ClaimRound[]) public claimRounds;
    mapping (address => uint8) public currentRounds;

    mapping (uint256 => address) requestIdToNFT;
    mapping (uint256 => uint256) requestIdToPropId;
    mapping (uint256 => bool) requestIdToDynamic;  
    mapping (uint256 => bool) servedProp;  

    /**
    ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
      ERRORS
    ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
    **/

    error AvailNFTsZero();   
    error ClaimPeriodNotFinished(); 
    error NoClaimRoundsOpen();
    error OnlyTokenOwnerCanClaim();
    error InvalidIndex();
    error InvalidRound();
    error ClaimPeriodEnded();
    error AlreadyClaimed();    
    error RoundIsTooBig(); // maximum round size is 256 NFTs
    error MustHaveAtLeastOneWinner();
    error PropIdMismatch();
    error CantReplayProp();

    /**
    ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
      CONSTRUCTOR
    ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
    **/

    constructor(uint64 subscriptionId, INFTBatchTransfer batchTransferAddress) VRFv2Consumer(subscriptionId) {
      NFT_BATCH_TRANSFER = batchTransferAddress;
    }    

    /**
    ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
      INTERNAL FUNCTIONS
    ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
    **/

    /// @notice Receives randomness; determines which wallets and quantities will have claimable NFTs. The more tokens are in the wallet, the more likely it is that it will get each individual NFTs awarded.
    /// @param _requestId Id of the VRF request
    /// @param _randomWords array of random numbers returned from VRF
    function fulfillRandomWords(
        uint256 _requestId,
        uint256[] memory _randomWords
    ) internal override {

        super.fulfillRandomWords(_requestId, _randomWords);

        address nftAddress = requestIdToNFT[_requestId];
        uint256 propId = requestIdToPropId[_requestId];
        bool isDynamicDistribution = requestIdToDynamic[_requestId];
        uint8 currentRound = currentRounds[nftAddress];

        if ((claimRounds[nftAddress].length > 0) && (block.number <= claimRounds[nftAddress][currentRound].endBlock)) {
          revert ClaimPeriodNotFinished();
        }        

        uint256 availNFTs = remainingAllowance(nftAddress);
        if (availNFTs > 256) {
          revert RoundIsTooBig();
        }

        if (availNFTs == 0) {
          revert AvailNFTsZero(); 
        }     

        if (claimRounds[nftAddress].length > 0) {
          currentRounds[nftAddress]++;
          currentRound = currentRounds[nftAddress];
        }
        claimRounds[nftAddress].push();
        ClaimRound storage round = claimRounds[nftAddress][currentRound];
        round.id = currentRound;
        round.startBlock = uint32(block.number);
        round.endBlock = uint32(block.number + CLAIM_WINDOW);
        uint256 nounSupply = NOUNS_TOKEN.totalSupply();
        round.nounSupply = uint16(nounSupply);     
        if (isDynamicDistribution) {
          ProposalCondensed memory proposal = NOUNS_DAO_PROXY.proposals(propId);
          round.numberWon = calcNumWinners(nounSupply, proposal.forVotes, proposal.againstVotes, proposal.abstainVotes, availNFTs);
        }
        else {
          round.numberWon = uint8(availNFTs);   
        }
        round.randomness = uint152(_randomWords[0]);

        emit RoundFulfilled(nftAddress, currentRound, uint8(availNFTs), uint152(_randomWords[0]));

    }

    /// @notice Checks if NFT is already claimed in the bitmap
    /// @param nftAddress address of the NFT collection being claimed
    /// @param index bitmap index of the NFT being claimed
    function _isClaimed(address nftAddress, uint8 index) internal view returns (bool) {
        uint8 currentRound = currentRounds[nftAddress];
        return claimRounds[nftAddress][currentRound].claimedBitmap & 1 << index != 0;
    }

    /// @notice Sets an NFT as already claimed in the bitmap
    /// @param nftAddress address of the NFT collection being claimed
    /// @param index bitmap index of the NFT being claimed
    function _setClaimed(address nftAddress, uint8 index) internal {
        uint8 currentRound = currentRounds[nftAddress];
        claimRounds[nftAddress][currentRound].claimedBitmap |= 1 << index;
    }  

    /// @notice Calculates number of NFT winners for the round based on voter turnout
    /// @param nounSupply address of the NFT collection being claimed
    /// @param forVotes number of for votes the prop got
    /// @param againstVotes number of against votes the prop got    
    /// @param abstainVotes number of abstain votes the prop got    
    /// @param maxWinners max number of NFTs to be distributed
    function calcNumWinners(uint256 nounSupply, uint256 forVotes, uint256 againstVotes, uint256 abstainVotes, uint256 maxWinners) internal pure returns (uint8) {
        // PENDING: implement this        
        return uint8((forVotes + againstVotes + abstainVotes) / nounSupply * maxWinners);
    }  

    /// @notice Returns id of first reference to this contract address in the list of prop targets. Assumes that prop will only call this contract once.
    /// @param targets list of addresses that prop is targeting
    function findTargetId(address[] memory targets) internal view returns (uint256) {
        for (uint256 i; i < targets.length; i++) {
          if (targets[i] == address(this)) {
            return (i+1);
          }
        }
        return 0;
    }

    /// @notice Compares prop action parameters against self-referencing call to the contract when the prop is executing
    /// @param propId id of the prop passed in the calldata when the prop was built
    function compareProps(uint256 propId) internal view {
        (
          address[] memory targets, 
          uint256[] memory values,
          string[] memory signatures,
          bytes[] memory calldatas
        ) = NOUNS_DAO_PROXY.getActions(propId);

        if (targets.length == 0) {
          revert PropIdMismatch();
        }
        
        uint256 targetId = findTargetId(targets);
        if (targetId == 0) {
          revert PropIdMismatch();
        }
        targetId--;

        if (values[targetId] > 0) {
          revert PropIdMismatch();
        }     

        if (keccak256(abi.encodePacked((signatures[targetId]))) != keccak256(abi.encodePacked(("requestRound(address,uint256,bool)")))) {
          revert PropIdMismatch();
        }

        if (keccak256(msg.data) != 
              keccak256(abi.encodePacked(bytes4(keccak256(abi.encodePacked(bytes(signatures[targetId])))), 
              calldatas[targetId]))) {
          revert PropIdMismatch();
        }      
    }

    /**
    ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
      PUBLIC & EXTERNAL VIEW FUNCTIONS
    ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
    **/

    /// @notice Get number of claimed NFTs per round
    /// @param round round number
    function numberClaimedNFTs(address nftAddress, uint256 round) external view returns (uint256) {
      return (claimRounds[nftAddress].length > 0) ? claimRounds[nftAddress][round].numberClaimed : 0;
    }

    /// @notice Get remaining NFTs allowance for this contract
    /// @param nftAddress address of NFT collection
    function remainingAllowance(address nftAddress) public view returns (uint256) {    
      return NFT_BATCH_TRANSFER.allowanceFor(nftAddress, address(this));
    }

    /// @notice Get remaining claimable number of NFTs this round. First check if this contract's allowance was taken away and in this case, return 0.
    /// @param nftAddress address of NFT collection    
    function remainingClaimableCurrentRound(address nftAddress) external view returns (uint256) { 
      uint8 currentRound = currentRounds[nftAddress];
      if (remainingAllowance(nftAddress) == 0) {
        return 0;
      }   
      else if ((claimRounds[nftAddress].length > 0) && block.number <= claimRounds[nftAddress][currentRound].endBlock) {
        return claimRounds[nftAddress][currentRound].numberWon - claimRounds[nftAddress][currentRound].numberClaimed;
      }
      else {
        return 0;
      }
    }

    /// @notice Expired NFTs that were not claimed in the last expired round. 
    /// @param nftAddress address of NFT collection    
    function expiredNFTsLastRound(address nftAddress) public view returns (uint256) { 
      uint8 currentRound = currentRounds[nftAddress];    
      if ((claimRounds[nftAddress].length > 0) && block.number > claimRounds[nftAddress][currentRound].endBlock) {
        return claimRounds[nftAddress][currentRound].numberWon - claimRounds[nftAddress][currentRound].numberClaimed;
      }
      else if ((claimRounds[nftAddress].length > 1) && block.number <= claimRounds[nftAddress][currentRound].endBlock) { // Current round still alive but previous round exists
        return claimRounds[nftAddress][currentRound-1].numberWon - claimRounds[nftAddress][currentRound-1].numberClaimed;
      }
      else {
        return 0;
      }
    }   

    /// @notice Returns number of NFTs that should be allocated for new round taking into account current allowance and number of NFTs desired to distributed in new round. If there is a round currently open, will return 0.
    /// @param nftAddress address of NFT collection    
    /// @param numberToDistribute the number of NFTs looking to distribute
    function additionalAllowanceRequiredFor(address nftAddress, uint256 numberToDistribute) external view returns (uint256) { 
      uint8 currentRound = currentRounds[nftAddress];       
      if ((claimRounds[nftAddress].length == 0) || (block.number > claimRounds[nftAddress][currentRound].endBlock)) {
        return (numberToDistribute >= remainingAllowance(nftAddress)) ? (numberToDistribute - remainingAllowance(nftAddress)) : 0;
      }
      else {
        return 0;
      }
    }

    /// @notice Returns number of NFTs that are claimable by an address
    /// @param nftAddress address of NFT collection    
    /// @param receiver address that would claim NFTs
    function claimableNFTs(address nftAddress, address receiver) external view returns (uint256 numNFTs) {    
      uint8 currentRound = currentRounds[nftAddress];
      // First check if there is a current claim round open
      if ((claimRounds[nftAddress].length == 0) || (block.number > claimRounds[nftAddress][currentRound].endBlock)) {
        return 0;
      }

      ClaimRound memory round = claimRounds[nftAddress][currentRound];

      for (uint8 i = 0; i < round.numberWon; ) {
            if (_isClaimed(nftAddress, i)) {
                continue;
            }

            if (receiver == NOUNS_TOKEN.ownerOf(uint256(keccak256(abi.encode(round.randomness, i))) % round.nounSupply)) {
                numNFTs++;
            }

            unchecked {
                ++i;
            }
      }
    }      

    /// @notice Returns remaining number of blocks until current claim period expires
    /// @param nftAddress address of NFT collection    
    function blocksUntilClaimExpires(address nftAddress) external view returns (uint256) 
    {        
      uint8 currentRound = currentRounds[nftAddress];
      if ((claimRounds[nftAddress].length == 0) || (block.number > claimRounds[nftAddress][currentRound].endBlock)) {
        return 0;
      }

      return claimRounds[nftAddress][currentRound].endBlock + 1 - block.number; // adding one because expiry will be the block after endBlock
    }

    /**
    ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
      PUBLIC & EXTERNAL FUNCTIONS
    ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
    **/


    /// @notice Request randomness for a new NFT distribution round
    /// @param nftAddress address of the NFT collection being distributed
    /// @param propId id of the prop that corresponds to this distribution round
    /// @param isDynamicDistribution Informs if the NFTs are to be distributed dynamically according to the number of for votes. Any non-zero value indicates 'yes'
    function requestRound(address nftAddress, uint256 propId, bool isDynamicDistribution) external onlyOwner returns (uint256 requestId) {
        uint256 availNFTs = remainingAllowance(nftAddress);
        if (availNFTs > 256) {
          revert RoundIsTooBig();
        }

        // Prevent replay attack
        if (servedProp[propId]) {
          revert CantReplayProp();
        }        

        // Verify prop being executed corresponds to propId in calldata
        compareProps(propId);
        servedProp[propId] = true;

        requestId = requestRandomWords();
        requestIdToNFT[requestId] = nftAddress;
        requestIdToPropId[requestId] = propId;
        requestIdToDynamic[requestId] = isDynamicDistribution;

        emit RoundRequested(requestId, nftAddress);
    }

    /// @notice Claim NFTs
    /// @param nftAddress address of the NFT being claimed
    /// @param index The winning index
    /// @param suggStartId Option to save gas by suggesting a starting search point for the NFT startId. Optionally, could be set to zero.
    function claim(address nftAddress, uint8 index, uint256 suggStartId) external {
        uint8 currentRound = currentRounds[nftAddress];
        ClaimRound memory round = claimRounds[nftAddress][currentRound];
        if (round.randomness == 0) {
            revert InvalidRound();
        }
        if (index >= round.numberWon) {
            revert InvalidIndex();
        }
        if (block.number > round.endBlock) {
            revert ClaimPeriodEnded();
        }
        if (_isClaimed(nftAddress, index)) {
            revert AlreadyClaimed();
        }

        uint256 startId = NFT_BATCH_TRANSFER.getStartId(ERC721Like(nftAddress), suggStartId);

        address owner = NOUNS_TOKEN.ownerOf(
            uint256(keccak256(abi.encode(round.randomness, index))) % round.nounSupply
        );
        if (msg.sender != owner) {
            revert OnlyTokenOwnerCanClaim();
        }

        _setClaimed(nftAddress, index);

        NFT_BATCH_TRANSFER.sendNFTs(ERC721Like(nftAddress), startId, owner);

        emit NFTClaimed(nftAddress, currentRound, index, owner);
    }

    /// @notice Claim many NFTs
    /// @param nftAddress address of the NFT being claimed
    /// @param indexes The winning indexes
    /// @param suggStartId Option to save gas by suggesting a starting search point for the NFT startId. Optionally, could be set to zero.
    function claimMany(address nftAddress, uint8[] calldata indexes, uint256 suggStartId) external {
        uint8 currentRound = currentRounds[nftAddress];
        ClaimRound memory round = claimRounds[nftAddress][currentRound];
        if (round.randomness == 0) {
            revert InvalidRound();
        }
        if (block.number > round.endBlock) {
            revert ClaimPeriodEnded();
        }

        // It is assumed that this contract has a sufficient allowance
        uint256 startId = NFT_BATCH_TRANSFER.getStartId(ERC721Like(nftAddress), suggStartId);

        uint256 indexCount = indexes.length;
        address[] memory recipients = new address[](indexCount);
        for (uint256 i = 0; i < indexCount; ) {
            uint8 index = indexes[i];
            if (index >= round.numberWon) {
                revert InvalidIndex();
            }
            if (_isClaimed(nftAddress, index)) {
                revert AlreadyClaimed();
            }

            recipients[i] = NOUNS_TOKEN.ownerOf(
                uint256(keccak256(abi.encode(round.randomness, index))) % round.nounSupply
            );
            if (msg.sender != recipients[i]) {
                revert OnlyTokenOwnerCanClaim();
            }

            _setClaimed(nftAddress, index);

            emit NFTClaimed(nftAddress, currentRound, index, recipients[i]);

            unchecked {
                ++i;
            }
        }
        NFT_BATCH_TRANSFER.sendManyNFTs(ERC721Like(nftAddress), startId, recipients);
    }

}
