// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.13;

import {ERC721} from "@solmate/tokens/ERC721.sol"; // Solmate: ERC721
import {ERC20} from "@solmate/tokens/ERC20.sol"; // Solmate: ERC721
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol"; // OZ: MerkleProof
import {Ownable} from "./lib/Ownable.sol"; // BoredGenius: Barebones Ownable
import {VRFConsumerBaseV2} from "@chainlink/VRFConsumerBaseV2.sol"; // Chainlink: VRF Consumer
import {VRFCoordinatorV2Interface}  from "@chainlink/interfaces/VRFCoordinatorV2Interface.sol"; // Chainlink: VRF Coordinator

contract MBC is ERC721, Ownable, VRFConsumerBaseV2 {
    /// constants

    // TODO Rinkeby coordinator. For other networks,
    // see https://docs.chain.link/docs/vrf-contracts/#configurations
    address public constant vrfCoordinator =
        0x6168499c0cFfCaCD319c818142124B7A15E857ab;

    // TODO The gas lane to use, which specifies the maximum gas price to bump to.
    // For a list of available gas lanes on each network,
    // see https://docs.chain.link/docs/vrf-contracts/#configurations
    bytes32 public constant keyHash =
        0xd89b2bf150e3b9e13446986e571fb9cab24b13cea0a43ea20a6049a85cc807cc;

    uint32 public constant callbackGasLimit = 300000;


    ERC20 public constant APE =
        ERC20(0x4d224452801ACEd8B2F0aebE155379bb5D594381);
    ERC20 public constant POW =
        ERC20(0x43Ab765ee05075d78AD8aa79dcb1978CA3079258);
    uint16 public constant APE_ASSET = 1;
    uint16 public constant POW_ASSET = 2;
    uint16 public constant ETH_ASSET = 3;
    // bigger is better rng from VRF
    uint16 public constant requestConfirmations = 3;
    uint256 public constant MAX_SUPPLY = 8000;

    /// mutables
    uint256 public currentSupply;
    uint256 public random_offset;
    uint256 public APE_PRICE;
    uint256 public POW_PRICE;
    uint256 public ETH_PRICE;
    uint256 public APE_PRICE_PUBLIC;
    uint256 public POW_PRICE_PUBLIC;
    uint256 public ETH_PRICE_PUBLIC;

    string public baseURI;
    VRFCoordinatorV2Interface COORDINATOR;
    uint64 subscriptionId;
    bool public isRevealed;

    mapping(address => uint256) public hasClaimed;

    bytes32 public merkleRoot;

    uint256[] public randomWords;

    error ExceedsMaxSupply();
    error PaymentNotCorrect();
    error NotInMerkle();
    error AlreadyClaimed();

    event Claim(address indexed to, uint256 amount);

    constructor(uint64 _subscriptionId)
        ERC721("Martian Border Club", "MBC")
        VRFConsumerBaseV2(vrfCoordinator)
    {
        subscriptionId = _subscriptionId;
        COORDINATOR = VRFCoordinatorV2Interface(vrfCoordinator);
        _transferOwnership(msg.sender);
    }

    ///
    /// Public
    ///

    function claim(
        uint16 paymentAsset,
        uint256 proofAmount,
        uint256 mintAmount,
        bytes32[] calldata proof
    ) external payable {
        if (mintAmount > proofAmount) revert();
        // Verify merkle proof, or revert if not in tree
        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, proofAmount));
        bool isValidLeaf = MerkleProof.verify(proof, merkleRoot, leaf);
        if (!isValidLeaf) revert NotInMerkle();
        unchecked {
            // Throw if address has already claimed tokens
            if (hasClaimed[msg.sender] + mintAmount > proofAmount)
                revert AlreadyClaimed();

            /// true === is presale
            getPaid(paymentAsset, price(paymentAsset, true, mintAmount));

            // Set address to claimed
            hasClaimed[msg.sender] += mintAmount;

            // Mint tokens to address
            for (uint256 i = 0; i < mintAmount; i++) {
                _mint(msg.sender, currentSupply++);
            }
        }
        // Emit claim event
        emit Claim(msg.sender, mintAmount);
    }

    function mint(uint16 paymentAsset, uint256 amount) external payable {
        // TODO
        // Check amount to prevent overflows
        unchecked {
            if (currentSupply + amount > MAX_SUPPLY) revert ExceedsMaxSupply();

            /// false === is not presale
            getPaid(paymentAsset, price(paymentAsset, false, amount));

            for (uint256 i = 0; i < amount; i++) {
                _mint(msg.sender, currentSupply++);
            }
        }
    }

    /// View

    function tokenURI(uint256 id) public view override returns (string memory) {
        if (isRevealed) {
            uint256 newID = id + random_offset;
            if (newID > MAX_SUPPLY) {
              newID -= MAX_SUPPLY;
            }
            return string(abi.encodePacked(baseURI, uint2str(newID)));
        } else {
            return baseURI;
        }
    }

    ///
    /// Only Owner
    ///

    function setPrice(
        uint256 ape,
        uint256 pow,
        uint256 eth
    ) external onlyOwner {
        APE_PRICE = ape;
        POW_PRICE = pow;
        ETH_PRICE = eth;
    }

    function setPublicPrice(
        uint256 ape,
        uint256 pow,
        uint256 eth
    ) external onlyOwner {
        APE_PRICE_PUBLIC = ape;
        POW_PRICE_PUBLIC = pow;
        ETH_PRICE_PUBLIC = eth;
    }

    function setBaseURI(string calldata _baseURI) external onlyOwner {
        baseURI = _baseURI;
    }

    function reveal(bool _isRevealed) external onlyOwner {
        random_offset = (randomWords[0] % MAX_SUPPLY) + 1;
        isRevealed = _isRevealed;
    }

    function setMerkleRoot(bytes32 _root) external onlyOwner {
        merkleRoot = _root;
    }

    function requestRandomWord() external onlyOwner {
        // Will revert if subscription is not set and funded.
        COORDINATOR.requestRandomWords(
            keyHash,
            subscriptionId,
            requestConfirmations,
            callbackGasLimit,
            1
        );
    }

    function ownerMint(address[] calldata to) external onlyOwner {
        if (currentSupply + to.length > MAX_SUPPLY) revert ExceedsMaxSupply();
        unchecked {
            for (uint256 i = 0; i < to.length; i++) {
                _mint(to[i], currentSupply++);
            }
        }
    }

    function withdraw(address payable to) external onlyOwner {
        (bool success, ) = to.call{value: address(this).balance}("");
        require(success);
        APE.transferFrom(address(this), to, APE.balanceOf(address(this)));
        POW.transferFrom(address(this), to, POW.balanceOf(address(this)));
    }

    ///
    /// Internal
    ///

    /// With side effects

    function getPaid(uint16 asset, uint256 _price) internal {
        if (asset == APE_ASSET) {
            APE.transferFrom(msg.sender, address(this), _price);
        }

        if (asset == POW_ASSET) {
            POW.transferFrom(msg.sender, address(this), _price);
        }

        if (asset == ETH_ASSET) {
            if (msg.value != _price) revert PaymentNotCorrect();
        }
    }

    function fulfillRandomWords(uint256, uint256[] memory _randomWords)
        internal
        override
    {
        randomWords = _randomWords;
    }

    /// View

    function price(
        uint16 asset,
        bool isPresale,
        uint256 amount
    ) internal view returns (uint256 _price) {
        unchecked {
            if (isPresale) {
                if (asset == APE_ASSET) _price = APE_PRICE * amount;
                if (asset == POW_ASSET) _price = POW_PRICE * amount;
                if (asset == ETH_ASSET) _price = ETH_PRICE * amount;
            } else {
                if (asset == APE_ASSET) _price = APE_PRICE_PUBLIC * amount;
                if (asset == POW_ASSET) _price = POW_PRICE_PUBLIC * amount;
                if (asset == ETH_ASSET) _price = ETH_PRICE_PUBLIC * amount;
            }
        }
    }

    function uint2str(uint256 _i)
        internal
        pure
        returns (string memory _uintAsString)
    {
        unchecked {
            if (_i == 0) {
                return "0";
            }
            uint256 j = _i;
            uint256 len;
            while (j != 0) {
                len++;
                j /= 10;
            }
            bytes memory bstr = new bytes(len);
            uint256 k = len;
            while (_i != 0) {
                k = k - 1;
                uint8 temp = (48 + uint8(_i - (_i / 10) * 10));
                bytes1 b1 = bytes1(temp);
                bstr[k] = b1;
                _i /= 10;
            }
            return string(bstr);
        }
    }
}
