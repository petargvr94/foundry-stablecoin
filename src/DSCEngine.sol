// SPDX-License-Identifier: MIT

// This is considered an Exogenous, Decentralized, Anchored (pegged), Crypto Collateralized low volitility coin

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

// HOW DECIMALS DON'T WORK IN SOLIDITY
pragma solidity 0.8.20;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title DSCEngine
 * @author Petar Gavrilov
 *
 * The system is designed to be as minimal as possible, and have the tokens
 * maintain 1 token == 1 $ peg.
 * This stablecoin has the propertyies:
 * - Exogenous Collateral
 * - Dollar Pegged
 * - Algoritmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees and was only backed by WETH and WBTC
 *
 * Our DSC system should always be "overcollateralized". At no point, should the value
 * of all collateral <= the $ backed value of all the DSC.
 *
 * @notice This contract is the core of the DSC System. It handles all the logic for mining and redeeming DSC - as well as depositing & withdrawing collateral.
 * @notice This contract is VERY loosely based on the MakerDAO DSS (DAI) system.
 */
contract DSCEngine {
    /////////////
    //Errors    //
    /////////////
    error DSCEngine_NeedsMoreThanZero();
    error DSCEngine_TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine_NotAllowedToken();
    error DSCEngine_TransferFailed();
    error DSCEngine_BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine_MintFailed();
    error DSCEngine_HealthFactorOk();
    error DSCEngine_HealthFactorNotImproved();

    /////////////
    //State Variables    //
    /////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // this means 10% bonus

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    ///////////
    //Events //
    ////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount);

    ///////////
    //Modifiers //
    ////////////
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine_NeedsMoreThanZero();
        }
        _; // WHAT IS THE PURPOSE OF THE UNDERSCO
    }

    modifier IsAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine_NotAllowedToken();
        }
        _;
    }

    ///////////
    //Functions //
    ////////////
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddress, address dscAddress) {
        // USD PRICE FEEDS
        if (tokenAddresses.length != priceFeedAddress.length) {
            revert DSCEngine_TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        // For example ETH/ USD, BTC/USD, MKR/USD , etc
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddress[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    ///////////
    //External Functions //
    ////////////

    /*
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     * @param amountDscToMint The amount of decentralized stablecoin to mint
     * @notice this function will deposit your collateral and mint DSC in one transcation
     * 
     * 
     */

    function depositCollateralAndMintDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDSCToMint) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDSCToMint);
    }

    /*
     * @notice follows CEI
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        IsAllowedToken(tokenCollateralAddress)
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        // WHY DO WE EMIT EVENTS WHEN WE UPDATE STATE VARIABLES?
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool sucess = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!sucess) {
            revert DSCEngine_TransferFailed();
        }
    }

    /*
    * @param tokenCollateralAddress The collteral address to redeem
    * @param amountCollateral The amount of collateral to redeem
    * @param amountDscToBurn The amount of DSC to burn
    * This function burns DSC and redeems underyling collateral in one transcation
    *
    */
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral,
    uint256 amountDscToBurn) external {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        // redeemCollateral already checks healtfactor
    }

    // Threshold to let's say 150%
    // $100 ETH Collateral -> $0
    // $0 DSC
    // UNDERCOLLATERALIZED

    // I'll pay back the $50DSC -> Get all your collateral
    // $74 ETH
    // -$50 DSC
    // $24

    // Healh factor must be over
    // DRY
    // CEI -> Checks effects interactions
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral) public moreThanZero(amountCollateral) {
      _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
      _revertIfHealthFactorIsBroken(msg.sender);
    }

    /*
    * @notice follows CEI
    * @param amountDscToMint The amount of decentralized stablecoin to mint
    * @notice they must have more collateral value than the minimum threshold-
    */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) {
        s_DSCMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if(!minted){
            revert DSCEngine_MintFailed();
        }
    }

    // Do we need to check if this breaks the health factor;
    function burnDsc(uint256 amount) public moreThanZero(amount){
         _burnDsc(amount , msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    // Liquidation take $75 backing and burns off the $50DSC
    // If someone is almost undercollateralized we will pay you to liquidate them!

    /*
    *
    * @param collateral The erc20 collateral address to liquidate from the user
    * @param user The user who has broken the health factor. 
    * @notice You can partially liquidate a user.
    * @notice You will get a liquidation bonus for taking the users funds
    * @notice This function working assumes the protocol will be roughly 200%
    overcollateralized in order for this to work.
    * @notice A knogwn bug would if the protocol were 100% or less collateralized, then
    we wouldn't be able to incentive the liquidatiors
    * For example if the price of the collateral plummeted before anyone could be 
    liquidated.
    * 
    * Their healtfh factor show be below MIN_HEALTH_FACTOR
    * Follows CEI: Checks , Effects, Interactions
    */
    function liquidate(address collateral, address user, uint256 debtToCover) external moreThanZero(debtToCover) {
        // need to check healt factor of the user
        uint256 startingUserHealthFactor = _healthFactor(user);
        if(startingUserHealthFactor >= MIN_HEALTH_FACTOR){
            revert DSCEngine_HealthFactorOk();
        }
        // We want to burn their DSC "debt"
        // And take their collateral
        // bAD uSER:  $140 ETH, $100 DSC
        // debbtToCOVER = $100
        // $100 OF dsc = ??? ETH?
        // 0.05 ETH
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        // And give them a 10% bonus
        // So we are giving the liquidator $110 of WETH for 100 DSC

        // 0.05 ETH * 0.1 = 0.005 ETH. Getting 0.055
        uint256 bonusCollateral = (tokenAmountFromDebtCovered*LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);
        // We need to burn the DSC
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if(endingUserHealthFactor <= startingUserHealthFactor){
            revert DSCEngine_HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor() external view {}

    ///////////////////////////////
    //Private and Internal View Functions //
    /////////////////////////////

    /*
    * @dev Low-level internal function, do not call unless the function calling it is 
    * checking for health factors being broken
    */
    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
         s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if(!success) {
            revert DSCEngine_TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral) private {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
      emit CollateralRedeemed(from, to , tokenCollateralAddress, amountCollateral);
      bool success = IERC20(tokenCollateralAddress).transfer(msg.sender, amountCollateral);
      if(!success) {
        revert DSCEngine_TransferFailed();
      }
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /*
    * Returns how close to liquidation a user is
    * If a user goes below 1, then they can get liquidated
    */
    function _healthFactor(address user) private view returns (uint256) {
        // total DSC minted
        // total collateral VALUE
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);

         // If no DSC is minted, health factor is effectively infinite
        if (totalDscMinted == 0) {
          return type(uint256).max; // Maximum possible uint256 value
        }

        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        // $150 ETH / 100 DSC = 1.5
        // 150 * 50 = 7500 / 100= (75 / 100) < 1

        // $1000 eth / 100 dsc
        // 1000 * 50 = 50000 / 100 = (500/ 100) > 1
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

        // 1.Check health factor (do they have enough collateral)
        // 2.Revert if they don't
    function _revertIfHealthFactorIsBroken(address user) internal view {
       uint256 healthFactor = _healthFactor(user);
       if(healthFactor < MIN_HEALTH_FACTOR){
        revert DSCEngine_BreaksHealthFactor(healthFactor);
       }
    }

    ///////////////////////////////
    //Public and External View Functions //
    /////////////////////////////

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns(uint256) {
        // price of ETH(token)
        // $/ETH ETH ??
        // $2000 / ETH. $1000 = 0.5 ETH
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // ($10e18*1e18) / ($2000e8*1e10)
       return (usdAmountInWei * PRECISION) / (uint256(price)*ADDITIONAL_FEED_PRECISION);
    }


    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        // loop through each collateral token, get the amount they have deposited, and map it to
        // the price, to get the USD value
        for(uint256 i=0; i<s_collateralTokens.length; i++)
        {
        address token = s_collateralTokens[i];
        uint256 amount = s_collateralDeposited[user][token];
        totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    // This functions uses AggregatorV3Interface to get the price feeds of the token using
    // the s_price feeds structure which is defined upon contract initializtion
    // It gets the price for the provided token parameter but since the price is in 1e8
    // more conversion is needed so that the final result is in 1e18.
    function getUsdValue(address token, uint256 amount) public view returns(uint256) {
       AggregatorV3Interface priceFeed = AggregatorV3Interface (s_priceFeeds[token]);
       (,int256 price,,,) = priceFeed.latestRoundData();
       // 1 ETH = $1000
       // The returned value from CL will be 1000 * 1e8
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION; // (1000 * 1e18 * (1e10)) * 1000 * 1e18;
    }

    function getAccountInformation(address user) external view returns(uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
      (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }


   function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    
     function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }
}
