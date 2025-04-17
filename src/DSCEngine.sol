// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {console} from "forge-std/console.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

/**
 * @author  18Kara
 * @title   KDSCEngine
 * @notice  This contract handles the logic for minting and redeeming KDSC, as well as depositing & withdrawing collateral
 * @notice  No governance, no fees, backed by WETH, WBTC
 * @notice  This contract is loosely based on the MakerDAO DSS (DAI) system
 */
contract DSCEngine is ReentrancyGuard {
    /////////////
    // Errors ///
    /////////////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesLengthMismatch();
    error DSCEngine__TokenNotAllowed(address token);
    error DSCEngine__TransferFailed();
    error DSCEngine__BelowMinimumHealthFactor();
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    ////////////
    // Types ///
    ////////////
    using OracleLib for AggregatorV3Interface;

    /////////////////////
    // State Variables //
    /////////////////////
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // Only 50% of your collateral counts as "safe"
    uint256 private constant PRECISION = 1e18;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;

    mapping(address token => address priceFeed) private s_tokenToPriceFeed;
    DecentralizedStableCoin private immutable i_dsc;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;
    address[] private s_collateralTokens;

    /////////////
    // Events ///
    /////////////
    event CollateralDeposited(
        address indexed user, address indexed tokenCollateralAddress, uint256 indexed amountCollateral
    );
    event CollateralRedeemed(
        address indexed from, address indexed to, address indexed tokenCollateralAddress, uint256 amountCollateral
    );

    ///////////////
    // Modifiers //
    ///////////////
    modifier moreThanZero(uint256 _amount) {
        if (_amount <= 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address _token) {
        if (s_tokenToPriceFeed[_token] == address(0)) {
            revert DSCEngine__TokenNotAllowed(_token);
        }
        _;
    }

    ///////////////
    // Functions //
    ///////////////
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dsc) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesLengthMismatch();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_tokenToPriceFeed[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }

        i_dsc = DecentralizedStableCoin(dsc);
    }

    function depositCollateralAndMintDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDSC)
        external
    {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDSC);
    }

    /**
     * @notice  Follows CEI pattern
     * @dev     .
     * @param   tokenCollateralAddress  The address of the token to deposit as collateral
     * @param   amountCollateral        The amount of collateral to deposit
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);

        // IERC20 is an interface that defines how we can interact with any ERC-20 token
        // User must approve the contract to spend their tokens before calling this function (ERC20 approve())
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral); // trasfers WETH/WBTC
        require(success, DSCEngine__TransferFailed());
    }

    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 _amount)
        external
    {
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        burnDsc(_amount);
        // burnDsc already checks health factor
    }

    // Healfactor must be checked before redeeming collateral
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);

        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;

        _revertIfHealthFactorIsBroken(msg.sender);

        bool minted = i_dsc.mint(msg.sender, amountDscToMint);

        require(minted, DSCEngine__MintFailed());
    }

    function burnDsc(uint256 _amount) public moreThanZero(_amount) {
        _burnDSC(_amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice  A known bug is when the protocol were 100% or less collateralized, then we won't be able to incentive the liquidators
     * @notice  You can partially liquidate a user
     * @notice  You will get a liquidation bonus for liquidating a user
     * @param   user                   The address of the user to liquidate
     * @param   debtToCover            The amount of DSC to burn to improve user's health factor
     * @param   collateral             The address of the collateral to liquidate from the user
     */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        // check health factor of user (is user liquidatable?)
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor >= 1) {
            revert DSCEngine__HealthFactorOk();
        }

        // burn their DSC (debt) and take their collateral
        uint256 nativeTokenAmountFromDebtCovered = getNativeTokenAmountFromUsd(collateral, debtToCover);
        uint256 collateralBonus = (nativeTokenAmountFromDebtCovered * 10) / 10; // 10% liquidation bonus

        uint256 totalCollateralRedeemed = nativeTokenAmountFromDebtCovered + collateralBonus;

        _redeemCollateral(user, msg.sender, collateral, debtToCover);
        _burnDSC(debtToCover, user, msg.sender);

        // check current health factor
        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= userHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(user);
    }

    function getHealthFactor() external view {}

    function getAccountCollateralValueInUSD(address user) public view returns (uint256 totalCollateralValueInUSD) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUSD += getUsdValue(token, amount);
        }
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_tokenToPriceFeed[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();

        return (uint256((price * 1e10)) * amount) / 1e18;
    }

    // ETH = $2000 , we have $1000 DSC
    // Collateral user gets when liquidating => $1000 / 2000 = 0.5 ETH
    function getNativeTokenAmountFromUsd(address collateral, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_tokenToPriceFeed[collateral]);
        (, int256 price,,,) = priceFeed.latestRoundData();

        return (usdAmountInWei * PRECISION) / (uint256(price) * 1e10);
    }

    //////////////////////////////////
    // Internal & Private Functions //
    //////////////////////////////////
    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDSCMinted, uint256 collateralValueInUSD) = _getAccountInformation(user);

        if (totalDSCMinted == 0) {
            return type(uint256).max; // no DSC minted, max health factor
        }

        uint256 collateralAdjustedForThreshold = (collateralValueInUSD * LIQUIDATION_THRESHOLD) / 100;

        return (collateralAdjustedForThreshold * PRECISION) / totalDSCMinted;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);

        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BelowMinimumHealthFactor();
        }
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDSCMinted, uint256 collateralValueInUSD)
    {
        totalDSCMinted = s_DSCMinted[user];
        collateralValueInUSD = getAccountCollateralValueInUSD(user);
    }

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral)
        private
    {
        s_collateralDeposited[tokenCollateralAddress][from] -= amountCollateral; // already safened by Solc
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * @dev     do not call unless the function calling it is checking health factor
     */
    function _burnDSC(uint256 amountToBurn, address onBehalf, address dscFrom) private {
        s_DSCMinted[onBehalf] -= amountToBurn; // will automatically revert if amountToBurn > s_DSCMinted[onBehalf]
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountToBurn); // trasfers DSC

        if (!success) {
            revert DSCEngine__TransferFailed();
        }

        i_dsc.burn(amountToBurn); // burn() burns from the caller's balance, that's why we transferFrom() first
    }

    function getUserInformation(address user)
        external
        view
        returns (uint256 totalDSCMinted, uint256 collateralValueInUSD)
    {
        (totalDSCMinted, collateralValueInUSD) = _getAccountInformation(user);
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getCollateralBalanceOfUser(address user, address tokenCollateralAddress)
        external
        view
        returns (uint256 amountCollateral)
    {
        amountCollateral = s_collateralDeposited[user][tokenCollateralAddress];
    }

    function getCollateralTokenPriceFeed(address collateral) external view returns (address) {
        return s_tokenToPriceFeed[collateral];
    }
}
