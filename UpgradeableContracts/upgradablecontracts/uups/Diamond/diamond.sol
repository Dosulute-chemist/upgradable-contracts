// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface IDiamondCut {
    enum FacetCutAction { Add, Replace, Remove }

    struct FacetCut {
        address facetAddress;
        FacetCutAction action;
        bytes4[] functionSelectors;
    }

    function diamondCut(FacetCut[] calldata _diamondCut, address _init, bytes calldata _calldata) external;

    event DiamondCut(FacetCut[] _diamondCut, address _init, bytes _calldata);
}

interface IDiamondLoupe {
    struct Facet {
        address facetAddress;
        bytes4[] functionSelectors;
    }

    function facets() external view returns (Facet[] memory facets_);
    function facetFunctionSelectors(address _facet) external view returns (bytes4[] memory selectors_);
    function facetAddresses() external view returns (address[] memory addresses_);
    function facetAddress(bytes4 _functionSelector) external view returns (address facetAddress_);
}

interface IERC165 {
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

interface IERC173 {
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function owner() external view returns (address owner_);
    function transferOwnership(address _newOwner) external;
}

interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data) external returns (bytes4);
}


library LibDiamond {
    bytes32 constant DIAMOND_STORAGE_POSITION = keccak256("diamond.standard.diamond.storage");

    struct FacetAddressAndPosition {
        address facetAddress;
        uint96 functionSelectorPosition;
    }

    struct FacetFunctionSelectors {
        bytes4[] functionSelectors;
        uint256 facetAddressPosition;
    }

    struct DiamondStorage {
        mapping(bytes4 => FacetAddressAndPosition) selectorToFacetAndPosition;
        mapping(address => FacetFunctionSelectors) facetFunctionSelectors;
        address[] facetAddresses;
        mapping(bytes4 => bool) supportedInterfaces;
        address contractOwner;
    }

    function diamondStorage() internal pure returns (DiamondStorage storage ds) {
        bytes32 position = DIAMOND_STORAGE_POSITION;
        assembly {
            ds.slot := position
        }
    }

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event DiamondCut(IDiamondCut.FacetCut[] _diamondCut, address _init, bytes _calldata);

    function setContractOwner(address _newOwner) internal {
        DiamondStorage storage ds = diamondStorage();
        address previousOwner = ds.contractOwner;
        ds.contractOwner = _newOwner;
        emit OwnershipTransferred(previousOwner, _newOwner);
    }

    function contractOwner() internal view returns (address) {
        return diamondStorage().contractOwner;
    }

    function enforceIsContractOwner() internal view {
        require(msg.sender == diamondStorage().contractOwner, "LibDiamond: Must be contract owner");
    }

    function diamondCut(IDiamondCut.FacetCut[] memory _diamondCut, address _init, bytes memory _calldata) internal {
        for (uint256 i; i < _diamondCut.length; i++) {
            IDiamondCut.FacetCutAction action = _diamondCut[i].action;
            if (action == IDiamondCut.FacetCutAction.Add) {
                addFunctions(_diamondCut[i].facetAddress, _diamondCut[i].functionSelectors);
            } else if (action == IDiamondCut.FacetCutAction.Replace) {
                replaceFunctions(_diamondCut[i].facetAddress, _diamondCut[i].functionSelectors);
            } else {
                removeFunctions(_diamondCut[i].facetAddress, _diamondCut[i].functionSelectors);
            }
        }
        emit DiamondCut(_diamondCut, _init, _calldata);
        initializeDiamondCut(_init, _calldata);
    }

    function addFunctions(address _facet, bytes4[] memory _selectors) internal {
        require(_selectors.length > 0, "LibDiamond: No selectors in facet to cut");
        require(_facet != address(0), "LibDiamond: Add facet can't be address(0)");
        DiamondStorage storage ds = diamondStorage();
        uint96 selectorPosition = uint96(ds.facetFunctionSelectors[_facet].functionSelectors.length);
        if (selectorPosition == 0) {
            addFacet(ds, _facet);
        }
        for (uint256 i; i < _selectors.length; i++) {
            bytes4 selector = _selectors[i];
            require(
                ds.selectorToFacetAndPosition[selector].facetAddress == address(0),
                "LibDiamond: Can't add function that already exists"
            );
            addFunction(ds, selector, selectorPosition, _facet);
            selectorPosition++;
        }
    }

    function replaceFunctions(address _facet, bytes4[] memory _selectors) internal {
        require(_selectors.length > 0, "LibDiamond: No selectors in facet to cut");
        require(_facet != address(0), "LibDiamond: Replace facet can't be address(0)");
        DiamondStorage storage ds = diamondStorage();
        uint96 selectorPosition = uint96(ds.facetFunctionSelectors[_facet].functionSelectors.length);
        if (selectorPosition == 0) {
            addFacet(ds, _facet);
        }
        for (uint256 i; i < _selectors.length; i++) {
            bytes4 selector = _selectors[i];
            address oldFacet = ds.selectorToFacetAndPosition[selector].facetAddress;
            require(oldFacet != _facet, "LibDiamond: Can't replace function with same function");
            removeFunction(ds, oldFacet, selector);
            addFunction(ds, selector, selectorPosition, _facet);
            selectorPosition++;
        }
    }

    function removeFunctions(address _facet, bytes4[] memory _selectors) internal {
        require(_selectors.length > 0, "LibDiamond: No selectors in facet to cut");
        require(_facet == address(0), "LibDiamond: Remove facet address must be address(0)");
        DiamondStorage storage ds = diamondStorage();
        for (uint256 i; i < _selectors.length; i++) {
            bytes4 selector = _selectors[i];
            removeFunction(ds, ds.selectorToFacetAndPosition[selector].facetAddress, selector);
        }
    }

    function addFacet(DiamondStorage storage ds, address _facet) internal {
        enforceHasContractCode(_facet, "LibDiamond: New facet has no code");
        ds.facetFunctionSelectors[_facet].facetAddressPosition = ds.facetAddresses.length;
        ds.facetAddresses.push(_facet);
    }

    function addFunction(DiamondStorage storage ds, bytes4 _selector, uint96 _position, address _facet) internal {
        ds.selectorToFacetAndPosition[_selector].functionSelectorPosition = _position;
        ds.facetFunctionSelectors[_facet].functionSelectors.push(_selector);
        ds.selectorToFacetAndPosition[_selector].facetAddress = _facet;
    }

    function removeFunction(DiamondStorage storage ds, address _facet, bytes4 _selector) internal {
        require(_facet != address(0), "LibDiamond: Can't remove function that doesn't exist");
        require(_facet != address(this), "LibDiamond: Can't remove immutable function");
        uint256 selectorPosition = ds.selectorToFacetAndPosition[_selector].functionSelectorPosition;
        uint256 lastSelectorPosition = ds.facetFunctionSelectors[_facet].functionSelectors.length - 1;
        if (selectorPosition != lastSelectorPosition) {
            bytes4 lastSelector = ds.facetFunctionSelectors[_facet].functionSelectors[lastSelectorPosition];
            ds.facetFunctionSelectors[_facet].functionSelectors[selectorPosition] = lastSelector;
            ds.selectorToFacetAndPosition[lastSelector].functionSelectorPosition = uint96(selectorPosition);
        }
        ds.facetFunctionSelectors[_facet].functionSelectors.pop();
        delete ds.selectorToFacetAndPosition[_selector];
        if (lastSelectorPosition == 0) {
            uint256 lastFacetAddressPosition = ds.facetAddresses.length - 1;
            uint256 facetAddressPosition = ds.facetFunctionSelectors[_facet].facetAddressPosition;
            if (facetAddressPosition != lastFacetAddressPosition) {
                address lastFacetAddress = ds.facetAddresses[lastFacetAddressPosition];
                ds.facetAddresses[facetAddressPosition] = lastFacetAddress;
                ds.facetFunctionSelectors[lastFacetAddress].facetAddressPosition = facetAddressPosition;
            }
            ds.facetAddresses.pop();
            delete ds.facetFunctionSelectors[_facet].facetAddressPosition;
        }
    }

    function initializeDiamondCut(address _init, bytes memory _calldata) internal {
        if (_init == address(0)) {
            return;
        }
        enforceHasContractCode(_init, "LibDiamond: _init address has no code");
        (bool success, bytes memory error) = _init.delegatecall(_calldata);
        if (!success) {
            if (error.length > 0) {
                assembly {
                    revert(add(error, 32), mload(error))
                }
            } else {
                revert("LibDiamond: _init function reverted");
            }
        }
    }

    function enforceHasContractCode(address _contract, string memory _errorMessage) internal view {
        uint256 size;
        assembly {
            size := extcodesize(_contract)
        }
        require(size > 0, _errorMessage);
    }
}


contract Diamond {
    constructor(address _contractOwner, address _diamondCutFacet) payable {
        LibDiamond.setContractOwner(_contractOwner);

        // Register diamondCut() so the diamond can be upgraded later
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IDiamondCut.diamondCut.selector;
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: _diamondCutFacet,
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: selectors
        });
        LibDiamond.diamondCut(cut, address(0), "");
    }

    fallback() external payable {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        address facet = ds.selectorToFacetAndPosition[msg.sig].facetAddress;
        require(facet != address(0), "Diamond: Function does not exist");
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), facet, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    receive() external payable {}
}


contract DiamondCutFacet is IDiamondCut {
    function diamondCut(FacetCut[] calldata _diamondCut, address _init, bytes calldata _calldata) external override {
        LibDiamond.enforceIsContractOwner();
        LibDiamond.diamondCut(_diamondCut, _init, _calldata);
    }
}

contract DiamondLoupeFacet is IDiamondLoupe, IERC165 {
    function facets() external view override returns (Facet[] memory facets_) {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        uint256 numFacets = ds.facetAddresses.length;
        facets_ = new Facet[](numFacets);
        for (uint256 i; i < numFacets; i++) {
            address facetAddr = ds.facetAddresses[i];
            facets_[i].facetAddress = facetAddr;
            facets_[i].functionSelectors = ds.facetFunctionSelectors[facetAddr].functionSelectors;
        }
    }

    function facetFunctionSelectors(address _facet) external view override returns (bytes4[] memory) {
        return LibDiamond.diamondStorage().facetFunctionSelectors[_facet].functionSelectors;
    }

    function facetAddresses() external view override returns (address[] memory) {
        return LibDiamond.diamondStorage().facetAddresses;
    }

    function facetAddress(bytes4 _functionSelector) external view override returns (address) {
        return LibDiamond.diamondStorage().selectorToFacetAndPosition[_functionSelector].facetAddress;
    }

    function supportsInterface(bytes4 _interfaceId) external view override returns (bool) {
        return LibDiamond.diamondStorage().supportedInterfaces[_interfaceId];
    }
}

contract OwnershipFacet is IERC173 {
    function transferOwnership(address _newOwner) external override {
        LibDiamond.enforceIsContractOwner();
        LibDiamond.setContractOwner(_newOwner);
    }

    function owner() external view override returns (address) {
        return LibDiamond.contractOwner();
    }
}


library LibERC20 {
    bytes32 constant STORAGE_POSITION = keccak256("diamond.storage.erc20");

    struct Layout {
        string name;
        string symbol;
        uint256 totalSupply;
        mapping(address => uint256) balances;
        mapping(address => mapping(address => uint256)) allowances;
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            l.slot := position
        }
    }
}

contract ERC20Facet {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function name() external view returns (string memory) {
        return LibERC20.layout().name;
    }

    function symbol() external view returns (string memory) {
        return LibERC20.layout().symbol;
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function totalSupply() external view returns (uint256) {
        return LibERC20.layout().totalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return LibERC20.layout().balances[account];
    }

    function allowance(address owner_, address spender) external view returns (uint256) {
        return LibERC20.layout().allowances[owner_][spender];
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        LibERC20.layout().allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        LibERC20.Layout storage l = LibERC20.layout();
        uint256 allowed = l.allowances[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "ERC20: insufficient allowance");
            l.allowances[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    /// @notice Only the diamond owner can mint tokens
    function mint(address to, uint256 amount) external {
        LibDiamond.enforceIsContractOwner();
        require(to != address(0), "ERC20: mint to zero address");
        LibERC20.Layout storage l = LibERC20.layout();
        l.totalSupply += amount;
        l.balances[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(to != address(0), "ERC20: transfer to zero address");
        LibERC20.Layout storage l = LibERC20.layout();
        require(l.balances[from] >= amount, "ERC20: insufficient balance");
        l.balances[from] -= amount;
        l.balances[to] += amount;
        emit Transfer(from, to, amount);
    }
}


library LibERC721 {
    bytes32 constant STORAGE_POSITION = keccak256("diamond.storage.erc721");

    struct Layout {
        string name;
        string symbol;
        uint256 nextTokenId;
        mapping(uint256 => address) owners;
        mapping(address => uint256) balances;
        mapping(uint256 => address) tokenApprovals;
        mapping(address => mapping(address => bool)) operatorApprovals;
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            l.slot := position
        }
    }
}

contract ERC721Facet {
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    function collectionName() external view returns (string memory) {
        return LibERC721.layout().name;
    }

    function collectionSymbol() external view returns (string memory) {
        return LibERC721.layout().symbol;
    }

    function nftTotalSupply() external view returns (uint256) {
        return LibERC721.layout().nextTokenId;
    }

    function nftBalanceOf(address owner_) external view returns (uint256) {
        require(owner_ != address(0), "ERC721: zero address");
        return LibERC721.layout().balances[owner_];
    }

    function ownerOf(uint256 tokenId) public view returns (address) {
        address owner_ = LibERC721.layout().owners[tokenId];
        require(owner_ != address(0), "ERC721: token does not exist");
        return owner_;
    }

    function getApproved(uint256 tokenId) external view returns (address) {
        ownerOf(tokenId);
        return LibERC721.layout().tokenApprovals[tokenId];
    }

    function isApprovedForAll(address owner_, address operator) public view returns (bool) {
        return LibERC721.layout().operatorApprovals[owner_][operator];
    }

    function nftApprove(address to, uint256 tokenId) external {
        address owner_ = ownerOf(tokenId);
        require(msg.sender == owner_ || isApprovedForAll(owner_, msg.sender), "ERC721: not allowed");
        LibERC721.layout().tokenApprovals[tokenId] = to;
        emit Approval(owner_, to, tokenId);
    }

    function setApprovalForAll(address operator, bool approved) external {
        LibERC721.layout().operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function nftTransferFrom(address from, address to, uint256 tokenId) public {
        _transfer(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        _transfer(from, to, tokenId);
        _checkReceiver(from, to, tokenId, "");
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata data) external {
        _transfer(from, to, tokenId);
        _checkReceiver(from, to, tokenId, data);
    }

    /// @notice Only the diamond owner can mint NFTs
    function mintNFT(address to) external returns (uint256 tokenId) {
        LibDiamond.enforceIsContractOwner();
        require(to != address(0), "ERC721: mint to zero address");
        LibERC721.Layout storage l = LibERC721.layout();
        tokenId = l.nextTokenId++;
        l.owners[tokenId] = to;
        l.balances[to]++;
        emit Transfer(address(0), to, tokenId);
    }

    function _transfer(address from, address to, uint256 tokenId) internal {
        LibERC721.Layout storage l = LibERC721.layout();
        address owner_ = ownerOf(tokenId);
        require(owner_ == from, "ERC721: from is not the owner");
        require(to != address(0), "ERC721: transfer to zero address");
        require(
            msg.sender == owner_ || l.tokenApprovals[tokenId] == msg.sender || isApprovedForAll(owner_, msg.sender),
            "ERC721: not allowed"
        );
        delete l.tokenApprovals[tokenId];
        l.balances[from]--;
        l.balances[to]++;
        l.owners[tokenId] = to;
        emit Transfer(from, to, tokenId);
    }

    function _checkReceiver(address from, address to, uint256 tokenId, bytes memory data) internal {
        if (to.code.length > 0) {
            try IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, data) returns (bytes4 retval) {
                require(retval == IERC721Receiver.onERC721Received.selector, "ERC721: bad receiver");
            } catch {
                revert("ERC721: receiver rejected");
            }
        }
    }
}


contract DiamondInit {
    function init(
        string memory tokenName,
        string memory tokenSymbol,
        string memory nftName,
        string memory nftSymbol
    ) external {
        LibERC20.Layout storage t = LibERC20.layout();
        t.name = tokenName;
        t.symbol = tokenSymbol;

        LibERC721.Layout storage n = LibERC721.layout();
        n.name = nftName;
        n.symbol = nftSymbol;

        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        ds.supportedInterfaces[type(IERC165).interfaceId] = true;
        ds.supportedInterfaces[type(IDiamondCut).interfaceId] = true;
        ds.supportedInterfaces[type(IDiamondLoupe).interfaceId] = true;
        ds.supportedInterfaces[type(IERC173).interfaceId] = true;
    }
}


contract DiamondDeployer {
    address public diamond;
    address public diamondCutFacet;
    address public loupeFacet;
    address public ownershipFacet;
    address public erc20Facet;
    address public erc721Facet;

    constructor() {
        DiamondCutFacet cutFacet = new DiamondCutFacet();
        Diamond d = new Diamond(address(this), address(cutFacet));
        DiamondLoupeFacet loupe = new DiamondLoupeFacet();
        OwnershipFacet ownership = new OwnershipFacet();
        ERC20Facet erc20 = new ERC20Facet();
        ERC721Facet erc721 = new ERC721Facet();
        DiamondInit init = new DiamondInit();

        diamond = address(d);
        diamondCutFacet = address(cutFacet);
        loupeFacet = address(loupe);
        ownershipFacet = address(ownership);
        erc20Facet = address(erc20);
        erc721Facet = address(erc721);

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](4);
        cuts[0] = IDiamondCut.FacetCut(address(loupe), IDiamondCut.FacetCutAction.Add, _loupeSelectors());
        cuts[1] = IDiamondCut.FacetCut(address(ownership), IDiamondCut.FacetCutAction.Add, _ownershipSelectors());
        cuts[2] = IDiamondCut.FacetCut(address(erc20), IDiamondCut.FacetCutAction.Add, _erc20Selectors());
        cuts[3] = IDiamondCut.FacetCut(address(erc721), IDiamondCut.FacetCutAction.Add, _erc721Selectors());

        IDiamondCut(address(d)).diamondCut(
            cuts,
            address(init),
            abi.encodeCall(DiamondInit.init, ("Diamond Token", "DMT", "Diamond NFT", "DNFT"))
        );

        // Give ownership of the diamond to whoever deployed this contract
        IERC173(address(d)).transferOwnership(msg.sender);
    }

    function _loupeSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](5);
        s[0] = DiamondLoupeFacet.facets.selector;
        s[1] = DiamondLoupeFacet.facetFunctionSelectors.selector;
        s[2] = DiamondLoupeFacet.facetAddresses.selector;
        s[3] = DiamondLoupeFacet.facetAddress.selector;
        s[4] = DiamondLoupeFacet.supportsInterface.selector;
    }

    function _ownershipSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = OwnershipFacet.owner.selector;
        s[1] = OwnershipFacet.transferOwnership.selector;
    }

    function _erc20Selectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](10);
        s[0] = ERC20Facet.name.selector;
        s[1] = ERC20Facet.symbol.selector;
        s[2] = ERC20Facet.decimals.selector;
        s[3] = ERC20Facet.totalSupply.selector;
        s[4] = ERC20Facet.balanceOf.selector;
        s[5] = ERC20Facet.allowance.selector;
        s[6] = ERC20Facet.transfer.selector;
        s[7] = ERC20Facet.approve.selector;
        s[8] = ERC20Facet.transferFrom.selector;
        s[9] = ERC20Facet.mint.selector;
    }

    function _erc721Selectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](13);
        s[0] = ERC721Facet.collectionName.selector;
        s[1] = ERC721Facet.collectionSymbol.selector;
        s[2] = ERC721Facet.nftTotalSupply.selector;
        s[3] = ERC721Facet.nftBalanceOf.selector;
        s[4] = ERC721Facet.ownerOf.selector;
        s[5] = ERC721Facet.getApproved.selector;
        s[6] = ERC721Facet.isApprovedForAll.selector;
        s[7] = ERC721Facet.nftApprove.selector;
        s[8] = ERC721Facet.setApprovalForAll.selector;
        s[9] = ERC721Facet.nftTransferFrom.selector;
        s[10] = bytes4(keccak256("safeTransferFrom(address,address,uint256)"));
        s[11] = bytes4(keccak256("safeTransferFrom(address,address,uint256,bytes)"));
        s[12] = ERC721Facet.mintNFT.selector;
    }
}