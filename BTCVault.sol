// SPDX-License-Identifier: MIT

pragma solidity >=0.8.0;

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

contract BTCVault is AutomationCompatibleInterface {

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
        uint256 amountBitcoin;
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
    
    IERC20 public constant BTC   = IERC20(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599); // Wrapped Bitcoin
    IERC20 public constant TOKEN = IERC20(0x0000000000000000000000000000000000000000); // Replace
    AggregatorV3Interface 
    private 
    constant 
    _BTC_PRICE_FEED = AggregatorV3Interface(0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c);

    address private _admin = msg.sender;
    address private _cold;

    mapping(uint256 => Vault)     public vaults;
    mapping(address => uint256[]) private _vaultIds;
    
    event VaultCreated(uint256 indexed id, uint256 amountToken, uint256 time);
    event VaultDeposit(uint256 indexed id, uint256 amountToken, uint256 amountBitcoin, uint256 time);
    event InterestPaid(uint256 indexed id, uint256 amountPaid, uint256 time);
    event InterestCollected(uint256 btcCollected, uint256 time);

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
     * @param amountBitcoin amount of wrapped BTC to deposit
     * @param amountToken amount of tokens to be minted
     *
     * Requirements:
     *
     * - `amountBitcoin` sent should produce a collateral percentage within the specified range
     * - `amountToken` should be greater than zero
     * - Caller must approve `amountBitcoin` beforehand
     *
     */
    function createVault(uint256 amountBitcoin, uint256 amountToken) external {
        if(amountBitcoin == 0 || amountToken == 0) revert INVALID_AMOUNT();

        uint256 collateralPercentage = (amountBitcoin * _getRate() * 10000) / amountToken; 

        if(
            collateralPercentage < minimumCollateralPercentage || collateralPercentage > maximumCollateralPercentage
        ) revert INVALID_COLLATERAL();

        uint256 vaultId;

        unchecked {
            vaultId = _counter++;
        }

        vaults[vaultId] = Vault(
            amountToken, 
            amountBitcoin, 
            collateralPercentage, 
            block.timestamp, 
            0,
            msg.sender
        );

        _vaultIds[msg.sender].push(vaultId);

        if(vaults[nextInterestPaymentId].lastPaidTimestamp == 0) nextInterestPaymentId = vaultId;

        BTC.transferFrom(msg.sender, address(this), amountBitcoin);
        TOKEN.mint(msg.sender, amountToken);

        emit VaultCreated(vaultId, amountToken, block.timestamp);
    }
    
    /**
     * @notice Deposit BTC to `vaultId`
     * `amountToken` tokens minted to caller
     *
     * @param vaultId id of vault to deposit to
     * @param amountBitcoin amount of wrapped BTC to deposit
     * @param amountToken amount of tokens to be minted
     * 
     * Requirements:
     * 
     * - `amountBitcoin` should be greater than zero
     * - `amountToken` should be greater than zero
     * - Caller must be vault owner
     * - New collateral % must be within valid range
     *
     */
    function depositToVault(uint256 vaultId, uint256 amountBitcoin, uint256 amountToken) external {
        if(amountBitcoin == 0 || amountToken == 0) revert INVALID_AMOUNT();
        Vault storage vault = vaults[vaultId];

        if(msg.sender != vault.account) 
            revert INVALID_CALLER();

        uint256 totalToken = vault.amountToken + amountToken;
        uint256 totalBTC = vault.amountBitcoin + amountBitcoin;
        uint256 newCollateralPercentage;

        unchecked { 
            newCollateralPercentage = (totalBTC * _getRate() * 10000) / totalToken;
        }

        if(newCollateralPercentage < minimumCollateralPercentage 
        || newCollateralPercentage > maximumCollateralPercentage) revert INVALID_COLLATERAL();

        vault.accInterest = totalInterest(vaultId);
        vault.lastPaidTimestamp = block.timestamp;

        vault.amountToken = totalToken;
        vault.amountBitcoin = totalBTC;
        vault.collateralPercentage = newCollateralPercentage;
        
        BTC.transferFrom(msg.sender, address(this), amountBitcoin);
        TOKEN.mint(msg.sender, amountToken);

        emit VaultDeposit(vaultId, amountToken, amountBitcoin, block.timestamp);
    }

    /**
     * @notice Pay accumulated interest for `vaultId`
     * @param vaultId id of vault to pay interest for
     * 
     * Requirements:
     *
     * - `vaultId` must have unpaid interest
     * - Caller must have approved sufficient Token tokens beforehand
     *
     * NOTE: Caller is not required to be the owner of `vaultId`
     *
     */
    function payInterest(uint256 vaultId) external {
        uint amount = totalInterest(vaultId);
        if(amount == 0) revert ZERO_AMOUNT();

        vaults[vaultId].lastPaidTimestamp = block.timestamp;
        vaults[vaultId].accInterest = 0;
        
        if(vaultId == nextInterestPaymentId) 
            _increment();

        TOKEN.transferFrom(msg.sender, _cold, amount);

        emit InterestPaid(vaultId, amount, block.timestamp);
    }

    /**
     * @notice Reimburse portion of borrowed Token tokens
     * @param vaultId id of vault to reimburse
     * @param amount amount of Token to reimburse
     *
     * Requirements:
     *
     * - Caller must be owner of `vaultId`
     * - `amount` must be non zero and less than or equal to initially borrowed amount
     * - `amount` of Token must have been approved beforehand
     *
     */
    function reimburse(uint256 vaultId, uint256 amount) external { 
        Vault storage vault = vaults[vaultId];
        if(msg.sender != vault.account) revert INVALID_CALLER();

        if(amount == 0 || amount > vault.amountToken) revert INVALID_AMOUNT();

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
    function refinance(uint256 vaultId, uint256 collateralPercentage) external {
        Vault storage vault = vaults[vaultId];
        if(msg.sender != vault.account) revert INVALID_CALLER();

        if(
            collateralPercentage < minimumCollateralPercentage || collateralPercentage > maximumCollateralPercentage
        ) revert INVALID_COLLATERAL();

        uint256 total = (_getRate() * vault.amountBitcoin * 10000) / collateralPercentage;
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

    function _getRate() private view returns (uint256) {
        ( ,int price, , , ) = _BTC_PRICE_FEED.latestRoundData();
        return uint256(price);
    }

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
            uint256 qty = totalInterest(nextInterestPaymentId) / (_getRate() * 100);

            vault.amountBitcoin = vault.amountBitcoin - qty;
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
    function totalInterest(uint vaultId) public view returns (uint256) {
        Vault storage vault = vaults[vaultId];
        uint256 perAnnum = (
            vault.amountToken * _findInterestRate(vault.collateralPercentage)
        ) / 10000;

        uint256 currentInterest = (perAnnum * (block.timestamp - vault.lastPaidTimestamp)) / 365 days;

        unchecked { return currentInterest + vault.accInterest; }
    }

    function btcExchangeRate() external view returns (uint256) {
        return _getRate() / 1e8; 
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

    /**
     * @notice Transfers total accumulated interest in BTC to cold wallet
     *
     */
    function collectInterest() external payable auth {
        uint256 amount = totalCollectableInterest;
        totalCollectableInterest = 0;

        BTC.transfer(_cold, amount);

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
     * @notice Transfer admin role to different address
     *
     */
    function adminRoleTransfer(address newAdmin) external payable auth {
        _admin = newAdmin;
    }

    /**
     * @notice Change refinance fee percentage
     * @param newRefinanceFeePercentage new refinance fee percentage
     *
     */
    function setRefinanceFee(uint256 newRefinanceFeePercentage) external payable auth {
        refinanceFeePercentage = newRefinanceFeePercentage;
    }

    /**
     * @notice Refund wrapped BTC for `vaultId`
     *
     */
    function refund(uint256 vaultId) external payable auth {
        uint256 currentBalance = vaults[vaultId].amountBitcoin;
        if(currentBalance == 0) revert ZERO_AMOUNT();
        
        vaults[vaultId].amountBitcoin = 0;
    
        BTC.transfer(vaults[vaultId].account, currentBalance);
    }

}
