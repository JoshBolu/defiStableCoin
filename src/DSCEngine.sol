// SPDX-License-Identifier: SEE LICENSE IN LICENSE

// Layout of Contract:
// license
// version
// imports
// errors
// interfaces, libraries, contracts
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
// internal & private view & pure functions
// external & public view & pure functions

pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
/*
 * @title DCSEngine
 * @author Suyi-Ajayi Boluwatife
 *
 * The System is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg.
 * This stabecoins has the properties:
 * - Exogenous Collateral
 * - Dollar pegged
 * - ALgorithmically stable
 *
 * It is similar to DAI if DAI had no governance, no fee, and was only backed by WETH and WBTC
 *
 * Our DSC system should always be "overcollateralized". At no point, should the value of all collateral <= the $ backed value of all the DSC
 *
 * @notice THis contract is the core of the DSC system. It handles all the logic for mining and redeeming DSC, as well as depositing & withdrawing collateral.
 * @notice This contract is VERY loosely based on the MakerDAO DSS (DAI) sytem
 */

contract DSCEngine is ReentrancyGuard {
    /*//////////////
     * Errors 
     /////////////*/
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAdddressesMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 userHealthFactor);
    error DSCEngine__MintFailed();

    /*//////////////
     * State variables 
     /////////////*/
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollaterized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1;

    mapping(address token => address priceFeed) private priceFeeds; // tokenToPriceFeed
    mapping(address user => mapping(address token => uint256 amount)) private collateralDeposit;
    mapping(address user => uint256 amountDscMinted) private DscMinted;

    address[] private collateralTokens;

    DecentralizedStableCoin private i_dsc;

    /*//////////////
     * Events 
     /////////////*/
    event CollateralDeposited(address, address, uint256);

    /*//////////////
     * Modifiers 
     /////////////*/
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    /*//////////////
     * Functions 
     /////////////*/

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        // USD Price Feeds
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAdddressesMustBeSameLength();
        }
        // for example ETH/USD, BTC/USD e.t.c
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /*//////////////
     * External Functions 
     /////////////*/
    function depositCollateralAndMintDSC() external {}

    /*
     * @notice follows CEI(Checks Effects Interactions)
     * @param tokenCollateralAddress: The address of the token to deposit as collateral
     * @param amountCollateral: The amount of collateral to deposit
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        external
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        collateralDeposit[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function redeemCollateral() external {}

    /*
    * @notice follows CEI
    * @param amountDscToMint The amount of decentralized stablecoins to mint
    * @notice they must have more collateral value than the minimum threshold  
    */
    function mintDsc(uint256 amountDscToMint) external moreThanZero(amountDscToMint) nonReentrant {
        DscMinted[msg.sender] += amountDscToMint;
        // If they minted too much ($150 DSC > $100 ETH)
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc() external {}

    function liquidate() external {}

    function getHealthFactor() external {}

    /*//////////////
     * Internal Functions 
     /////////////*/

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = DscMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /* 
    * Returns how close to liquidation a user is
    * if a user goes bellow 1, then they can get liquidated
    */
    function _healthFactor(address user) private view returns (uint256) {
        // total DSC minted
        // total collateral value
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION; // we doing this because decimals dont work in solidity
        // $150 ETH / 100 DSC (collateralInUsd / DSC)
        //  150 * 50 = 7500 / 100 = (75 / 100) < 1 - would be liquidated (would have an health factor of 75)

        // $1000 ETH / 100DSC
        // 1000 * 50 = 50000 / 100 = (500 / 100) > 1 - would not be liquidated (would have an health factor of 500)
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }
    // 1. Check health factot(checks if they have enough collateral)
    // 2. Revert if they dont

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    /*//////////////////////////////////
     * Public & External view Functions 
     /////////////////////////////////*/
    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        // loop through each collateral token, get the amount they have deposited, and map it to the price, to get the USD value
        for (uint256 i = 0; i < collateralTokens.length; i++) {
            address token = collateralTokens[i];
            uint256 amount = collateralDeposit[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }

        return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // 1 ETH = $100
        // The returned value from Cl will be 1000 * 1e8
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION; // (1000 * 1e8 * 1e10 * 1000 * 1e18)/ 1e18
    }
}
