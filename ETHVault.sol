// SPDX-License-Identifier: MIT

pragma solidity >=0.8.7;

import "@chainlink/contracts/src/v0.8/AutomationCompatible.sol";

interface AggregatorV3Interface {
  function latestRoundData()
    external
    view
    returns (
      uint80 roundId,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint80 answeredInRound
    );
}

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function mint(address account, uint256 amount) external;
    function burn(address account, uint256 amount) external;
}

contract ETHVault is AutomationCompatibleInterface {

    // =============================================================
    //                            ERRORS
    // ============================================================= 

    error INVALID_AMOUNT();
    error INVALID_COLLATERAL();
    error INVALID_CALLER();
    error ZERO_AMOUNT();

    // =============================================================
    //                            STORAGE
    // =============================================================

    struct Vault {
        uint256 amountToken;
        uint256 amountEth;
        uint256 collateralPercentage;
        uint256 lastPaidTimestamp;
        uint256 accInterest;
        address account;
    }

    uint256 private _counter; 

    uint256 public minimumCollateralPercentage = 120;
    uint256 public maximumCollateralPercentage = 500;
    uint256 public refinanceFeePercentage = 12;
    uint256 public nextInterestPaymentId;
    uint256 public totalCollectableInterest;

    uint256[6] public interestRates = [25, 99, 199, 299, 399, 449]; 
    
    IERC20 public constant TOKEN = IERC20(0x0000000000000000000000000000000000000000); 
    AggregatorV3Interface 
    private 
    constant 
    _ETH_PRICE_FEED = AggregatorV3Interface(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419); // Mainnet ETH / USD Chainlink oracle

    address private _admin = msg.sender;
    address private _cold;

    mapping(uint256 => Vault)     public vaults;
    mapping(address => uint256[]) private _vaultIds;
    
    event VaultCreated(uint256 indexed id, uint256 amountToken, uint256 time);
    event VaultDeposit(uint256 indexed id, uint256 amountToken, uint256 amountEth, uint256 time);
    event InterestPaid(uint256 indexed id, uint256 amountPaid, uint256 time);
    event InterestCollected(uint256 amountCollected, uint256 time); 

    modifier auth() {
        _authenticate();
        _;
    }

    constructor(address initColdWallet) { _cold = initColdWallet; }

    // =============================================================
    //                       VAULT FUNCTIONS
    // =============================================================

    /**
     * @notice Creates a new vault and mints `amountToken` tokens to the caller
     * @param amountToken amount of tokens to be minted
     * 
     * Requirements:
     *
     * - `amountToken` should be greater than zero
     * - Ether sent should produce a collateral percentage within the specified range
     *
     */
    function createVault(uint256 amountToken) external payable {
        if(msg.value == 0 || amountToken == 0) revert INVALID_AMOUNT();

        uint256 collateralPercentage = (msg.value * ethExchangeRate() * 100) / amountToken;

        if(collateralPercentage < minimumCollateralPercentage 
        || collateralPercentage > maximumCollateralPercentage) revert INVALID_COLLATERAL();

        uint256 vaultId;

        unchecked {
            vaultId = _counter++;
        }

        vaults[vaultId] = Vault(
            amountToken, 
            msg.value, 
            collateralPercentage, 
            block.timestamp, 
            0,
            msg.sender
        );

        _vaultIds[msg.sender].push(vaultId);

        if(vaults[nextInterestPaymentId].lastPaidTimestamp == 0) 
            nextInterestPaymentId = vaultId;

        TOKEN.mint(msg.sender, amountToken);

        emit VaultCreated(vaultId, amountToken, block.timestamp);
    }

    /**
     * @notice Deposit Eth to `vaultId`
     * `amountToken` tokens minted to caller
     *
     * @param vaultId id of vault to deposit to
     * @param amountToken amount of tokens to be minted
     * 
     * Requirements:
     *
     * - `amountToken` should be greater than zero
     * - Caller must be vault owner
     * - Ether sent should produce a collateral percentage within the specified range
     *
     */
    function depositToVault(uint256 vaultId, uint256 amountToken) external payable {
        if(msg.value == 0 || amountToken == 0) revert INVALID_AMOUNT();
        Vault storage vault = vaults[vaultId];

        if(msg.sender != vault.account) 
            revert INVALID_CALLER();

        uint256 totalTokens = vault.amountToken + amountToken;
        uint256 totalEth;
        uint256 newCollateralPercentage;

        unchecked { 
            totalEth = vault.amountEth + msg.value;
            newCollateralPercentage = (totalEth * ethExchangeRate() * 100) / totalTokens;
        }

        if(newCollateralPercentage < minimumCollateralPercentage 
        || newCollateralPercentage > maximumCollateralPercentage) revert INVALID_COLLATERAL();

        vault.accInterest = totalInterest(vaultId);
        vault.lastPaidTimestamp = block.timestamp;

        vault.amountToken = totalTokens;
        vault.amountEth = totalEth;
        vault.collateralPercentage = newCollateralPercentage;

        TOKEN.mint(msg.sender, amountToken);

        emit VaultDeposit(vaultId, amountToken, msg.value, block.timestamp);
    }

    /**
     * @notice Pay accumulated interest for `vaultId`
     * @param vaultId id of vault to pay interest for
     * 
     * Requirements:
     *
     * - `vaultId` must have unpaid interest
     * - Caller must have approved sufficient amerG tokens beforehand
     *
     * NOTE: Caller is not required to be the owner of `vaultId`
     *
     */
    function payInterest(uint256 vaultId) external payable {
        uint256 amount = totalInterest(vaultId);
        if(amount == 0) 
            revert ZERO_AMOUNT();

        vaults[vaultId].lastPaidTimestamp = block.timestamp;
        vaults[vaultId].accInterest = 0;
        
        if(vaultId == nextInterestPaymentId) 
            _increment();

        TOKEN.transferFrom(msg.sender, _cold, amount);

        emit InterestPaid(vaultId, amount, block.timestamp);
    }

    /**
     * @notice Reimburse portion of borrowed amerG tokens
     * @param vaultId id of vault to reimburse
     * @param amount amount of amerG to reimburse
     *
     * Requirements:
     *
     * - Caller must be owner of `vaultId`
     * - `amount` must be non zero and less than or equal to initially borrowed amount
     * - `amount` of amerG must have been approved beforehand
     *
     */
    function reimburse(uint256 vaultId, uint256 amount) external payable { 
        Vault storage vault = vaults[vaultId];

        if(msg.sender != vault.account) 
            revert INVALID_CALLER();
        if(amount == 0 || amount > vault.amountToken) 
            revert INVALID_AMOUNT();

        vault.accInterest = totalInterest(vaultId);
        vault.lastPaidTimestamp = block.timestamp;
        
        unchecked {
            vault.amountToken = vault.amountToken - amount;
        }

        TOKEN.burn(msg.sender, amount);
    }

    /**
     * @notice Refinance an active vault
     * @param vaultId id of vault to refinance
     * @param collateralPercentage new collateral percentage for vault
     *
     * Requirements:
     *
     * - Caller must be owner of `vaultId`
     * - `collateralPercentage` must be within specified range
     * - Caller must have approved refinance fee beforehand
     *
     */
    function refinance(uint256 vaultId, uint256 collateralPercentage) external payable {
        Vault storage vault = vaults[vaultId];
        if(msg.sender != vault.account) revert INVALID_CALLER();

        if(
            collateralPercentage < minimumCollateralPercentage || collateralPercentage > maximumCollateralPercentage
        ) revert INVALID_COLLATERAL();

        uint256 total = (ethExchangeRate() * vault.amountEth * 100) / collateralPercentage;
        uint256 fee;
        uint256 claimable;
        

        unchecked {
            fee = (vault.amountToken * refinanceFeePercentage) / 100;
            claimable = total - vault.amountToken - fee;
        }
        
        if(claimable == 0) revert ZERO_AMOUNT();

        vault.accInterest = totalInterest(vaultId);
        vault.lastPaidTimestamp = block.timestamp;
        vault.collateralPercentage = collateralPercentage;

        unchecked {
            vault.amountToken = vault.amountToken + claimable;
        }


        TOKEN.transferFrom(msg.sender, _cold, fee);
        
        TOKEN.mint(msg.sender, claimable);
    }
    

    // =============================================================
    //                          CHAINLINK 
    // =============================================================


    function checkUpkeep(
        bytes calldata /* checkData */
    )
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory /* performData */)
    {
        upkeepNeeded = vaults[nextInterestPaymentId].lastPaidTimestamp > 0 
        && 
        block.timestamp - vaults[nextInterestPaymentId].lastPaidTimestamp > 90 days;
    }

    function performUpkeep(bytes calldata /* performData */) external override {
        Vault storage vault = vaults[nextInterestPaymentId];
        if(
            vault.lastPaidTimestamp > 0 
            && 
            block.timestamp - vault.lastPaidTimestamp > 90 days
        ) 
        {
            uint256 qty = totalInterest(nextInterestPaymentId) / ethExchangeRate();

            vault.amountEth = vault.amountEth - qty;
            vault.lastPaidTimestamp = block.timestamp;
            vault.accInterest = 0;

            unchecked {
                 totalCollectableInterest = totalCollectableInterest + qty;
            }

            _increment();
        }

    }


    // =============================================================
    //                       GETTER FUNCTIONS 
    // =============================================================

    /**
     * @notice Returns current unpaid interest for `vaultId`
     *
     */
    function totalInterest(uint256 vaultId) public view returns (uint256) {
        Vault storage vault = vaults[vaultId];
        uint256 perAnnum = (
            vault.amountToken * _findInterestRate(vault.collateralPercentage)
        ) / 10000;

        uint256 currentInterest = (perAnnum * (block.timestamp - vault.lastPaidTimestamp)) / 365 days;

        unchecked { return currentInterest + vault.accInterest; }
    }

    function ethExchangeRate() public view returns (uint256) {
        ( ,int price, , , ) = _ETH_PRICE_FEED.latestRoundData();
        return uint256(price) / 1e8;
    }

    function totalVaults() external view returns (uint256) {
        return _counter;

    }

    function vaultsOf(address account) external view returns (uint256[] memory) {
        return _vaultIds[account];
    }
    
    
    // =============================================================
    //                       PRIVATE HELPERS
    // =============================================================

    function _findInterestRate(uint256 collateral) private view returns (uint256) {
        if(collateral >= 401 && collateral <= 500)
            return interestRates[0];
        else if(collateral >= 301 && collateral < 401)
            return interestRates[1];
        else if(collateral >= 251 && collateral < 301)
            return interestRates[2];
        else if(collateral >= 201 && collateral < 251)
            return interestRates[3];
        else if(collateral >= 171 && collateral < 201)
            return interestRates[4];
        else 
            return interestRates[5];
    }
    
    function _increment() private {
        unchecked {
            nextInterestPaymentId = nextInterestPaymentId + 1;
        }
            
        if(nextInterestPaymentId == _counter) nextInterestPaymentId = 0; 
    }

    function _authenticate() private view {
        if(_admin != msg.sender) revert INVALID_CALLER();
    }


    // =============================================================
    //                          ADMIN ONLY
    // =============================================================

    function collectInterest() external payable auth {
        uint256 amount = totalCollectableInterest;
        totalCollectableInterest = 0;
        payable(_cold).transfer(amount);

        emit InterestCollected(amount, block.timestamp);
    }

    /**
     * @notice Change interest rates
     * @param newInterestRates list containing new interest rates for each of the 6 collateral ranges sequentially
     *
     * Requirements:
     *
     * - Passed array must have 6 elements
     *
     */
    function setInterestRates(uint256[6] calldata newInterestRates) external payable auth {
        interestRates = newInterestRates;
    }

    /**
     * @notice Change cold wallet address
     * @param newColdWallet address of new cold wallet
     *
     */
    function setColdWallet(address newColdWallet) external payable auth {
        _cold = newColdWallet;
    }

    /**
     * @notice Change collateral percentage limits
     * @param minimum new minimum collateral percentage
     * @param maximum new maximum collateral percentage
     *
     */
    function setCollateralPercentages(uint256 minimum, uint256 maximum) external payable auth {
        minimumCollateralPercentage = minimum;
        maximumCollateralPercentage = maximum;
    }
    
    /**
     * @notice Change refinance fee percentage
     * @param newRefinanceFee new refinance fee percentage
     *
     */
    function setRefinanceFee(uint256 newRefinanceFee) external payable auth {
        refinanceFeePercentage = newRefinanceFee;
    }

    /**
     * @notice Transfer admin role to different address
     *
     */
    function adminRoleTransfer(address newAdmin) external payable auth {
        _admin = newAdmin;
    }

    /**
     * @notice Refund ether for `vaultId`
     *
     */
    function refund(uint256 vaultId) external payable auth {
        uint256 currentBalance = vaults[vaultId].amountEth;
        if(currentBalance == 0) 
            revert ZERO_AMOUNT();
        
        vaults[vaultId].amountEth = 0;
    
        (bool ok, ) = vaults[vaultId].account.call{value: currentBalance}("");
        require(ok);
    }

}
