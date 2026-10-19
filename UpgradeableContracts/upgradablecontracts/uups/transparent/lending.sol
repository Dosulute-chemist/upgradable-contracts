// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import  "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import  "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

/// @title LendingV1 - simple ETH lending: deposit collateral, borrow up to 50% of it
contract LendingV1 is Initializable, OwnableUpgradeable {
    uint256 public constant COLLATERAL_FACTOR = 50; // you can borrow 50% of your deposit

    mapping(address => uint256) public deposits;
    mapping(address => uint256) public debts;
    uint256 private _locked; // simple reentrancy guard

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event Borrowed(address indexed user, uint256 amount);
    event Repaid(address indexed user, uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize() public initializer {
        __Ownable_init(msg.sender);
        _locked = 1;
    }

    modifier nonReentrant() {
        require(_locked == 1, "Reentrant call");
        _locked = 2;
        _;
        _locked = 1;
    }

    function deposit() external payable {
        require(msg.value > 0, "Send some ETH");
        deposits[msg.sender] += msg.value;
        emit Deposited(msg.sender, msg.value);
    }

    function maxBorrow(address user) public view returns (uint256) {
        uint256 limit = (deposits[user] * COLLATERAL_FACTOR) / 100;
        return limit > debts[user] ? limit - debts[user] : 0;
    }

    function borrow(uint256 amount) external virtual nonReentrant {
        require(amount > 0, "Amount is zero");
        require(amount <= maxBorrow(msg.sender), "Exceeds borrow limit");
        require(amount <= address(this).balance, "Not enough liquidity");
        debts[msg.sender] += amount;
        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "Transfer failed");
        emit Borrowed(msg.sender, amount);
    }

    function repay() external payable nonReentrant {
        require(msg.value > 0, "Send some ETH");
        uint256 debt = debts[msg.sender];
        require(debt > 0, "No debt");
        uint256 payment = msg.value > debt ? debt : msg.value;
        debts[msg.sender] = debt - payment;
        uint256 refund = msg.value - payment;
        if (refund > 0) {
            (bool ok, ) = msg.sender.call{value: refund}("");
            require(ok, "Refund failed");
        }
        emit Repaid(msg.sender, payment);
    }

    /// @notice Withdraw collateral, but only what is not backing your debt
    function withdraw(uint256 amount) external nonReentrant {
        require(amount > 0 && amount <= deposits[msg.sender], "Invalid amount");
        uint256 remaining = deposits[msg.sender] - amount;
        require(debts[msg.sender] * 100 <= remaining * COLLATERAL_FACTOR, "Collateral locked by debt");
        deposits[msg.sender] = remaining;
        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "Transfer failed");
        emit Withdrawn(msg.sender, amount);
    }

    function version() external pure virtual returns (string memory) {
        return "V1";
    }
}

/// @title LendingV2 - upgrade: adds a borrow fee (in basis points) set by the owner
contract LendingV2 is LendingV1 {
    uint256 public borrowFeeBps; // new variable (appended). 100 = 1%
    uint256 public feesAccrued;  // new variable (appended)

    event FeeUpdated(uint256 newFeeBps);

    /// @notice Called once during the upgrade to set the starting fee
    function initializeV2(uint256 feeBps) external reinitializer(2) {
        require(feeBps <= 1000, "Fee too high"); // max 10%
        borrowFeeBps = feeBps;
    }

    function setBorrowFee(uint256 feeBps) external onlyOwner {
        require(feeBps <= 1000, "Fee too high");
        borrowFeeBps = feeBps;
        emit FeeUpdated(feeBps);
    }

    /// @dev Borrower receives `amount`, but owes amount + fee
    function borrow(uint256 amount) external override nonReentrant {
        require(amount > 0, "Amount is zero");
        uint256 fee = (amount * borrowFeeBps) / 10_000;
        require(amount + fee <= maxBorrow(msg.sender), "Exceeds borrow limit");
        require(amount <= address(this).balance, "Not enough liquidity");
        debts[msg.sender] += amount + fee;
        feesAccrued += fee;
        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "Transfer failed");
        emit Borrowed(msg.sender, amount);
    }

    function version() external pure override returns (string memory) {
        return "V2";
    }
}