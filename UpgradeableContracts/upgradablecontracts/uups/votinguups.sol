// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
// Imported only so Remix compiles the proxy and lets you deploy it
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title VotingV1 - first version of the UUPS voting contract
contract VotingV1 is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    struct Proposal {
        string description;
        uint256 yesVotes;
        uint256 noVotes;
    }

    Proposal[] internal proposals;
    // proposalId => voter => has voted
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    event ProposalCreated(uint256 indexed id, string description);
    event Voted(uint256 indexed id, address indexed voter, bool support);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers(); // the implementation itself can never be initialized
    }

    /// @notice Runs once through the proxy (replaces a constructor)
    function initialize() public initializer {
        __Ownable_init(msg.sender);
    }

    function createProposal(string calldata description) external onlyOwner returns (uint256 id) {
        proposals.push(Proposal(description, 0, 0));
        id = proposals.length - 1;
        emit ProposalCreated(id, description);
    }

    function vote(uint256 id, bool support) external virtual {
        require(id < proposals.length, "No such proposal");
        require(!hasVoted[id][msg.sender], "Already voted");
        hasVoted[id][msg.sender] = true;
        if (support) proposals[id].yesVotes++;
        else proposals[id].noVotes++;
        emit Voted(id, msg.sender, support);
    }

    function getProposal(uint256 id) external view returns (string memory description, uint256 yesVotes, uint256 noVotes) {
        require(id < proposals.length, "No such proposal");
        Proposal storage p = proposals[id];
        return (p.description, p.yesVotes, p.noVotes);
    }

    function proposalCount() external view returns (uint256) {
        return proposals.length;
    }

    function version() external pure virtual returns (string memory) {
        return "V1";
    }

    /// @dev UUPS: the upgrade logic lives in the implementation, so access control goes here
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}

/// @title VotingV2 - upgrade: owner can close proposals
/// @dev Inherits V1 and only APPENDS new storage, so the layout stays safe
contract VotingV2 is VotingV1 {
    mapping(uint256 => bool) public closed; // new variable (appended)

    event ProposalClosed(uint256 indexed id);

    function closeProposal(uint256 id) external onlyOwner {
        require(id < proposals.length, "No such proposal");
        closed[id] = true;
        emit ProposalClosed(id);
    }

    function vote(uint256 id, bool support) external override {
        require(id < proposals.length, "No such proposal");
        require(!closed[id], "Proposal closed");
        require(!hasVoted[id][msg.sender], "Already voted");
        hasVoted[id][msg.sender] = true;
        if (support) proposals[id].yesVotes++;
        else proposals[id].noVotes++;
        emit Voted(id, msg.sender, support);
    }

    function version() external pure override returns (string memory) {
        return "V2";
    }
}