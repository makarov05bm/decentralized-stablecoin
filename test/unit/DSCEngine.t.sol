// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from
    "@chainlink/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/mocks/ERC20Mock.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine engine;
    HelperConfig config;
    address wethUsdPriceFeed;
    address wbtcUsdPriceFeed;
    address weth;
    address wbtc;
    uint256 deployerKey;
    address USER = makeAddr("user");

    uint256 constant AMOUNT_COLLATERAL = 10 ether;
    uint256 constant AMOUNT_DSC = 50 ether;
    uint256 constant STARTING_COLLATERAL = 100 ether;

    address[] tokenAddresses;
    address[] priceFeedAddresses;

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    modifier depositedCollateralAndMintedDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_DSC);
        vm.stopPrank();
        _;
    }

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, engine, config) = deployer.run();

        (wethUsdPriceFeed, wbtcUsdPriceFeed, weth, wbtc, deployerKey) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_COLLATERAL); // give USER some WETH to play with
    }

    function test_revertIfTokenLengttIsNotEqualToPriceFeedLength() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(wethUsdPriceFeed);
        priceFeedAddresses.push(wbtcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesLengthMismatch.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    function test_getUsdValue() public view {
        uint256 ethAmount = 15e18;
        uint256 expectedValue = 30_000e18; // 15e18 * 2000e8
        uint256 actualValue = engine.getUsdValue(weth, ethAmount);
        assertEq(actualValue, expectedValue, "The USD value of 15 ETH should be 30,000 USD");
    }

    function test_revertIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function test_getNativeTokenAmountFromUSD() public view {
        uint256 usdAmount = 100e18;
        uint256 expectedAmount = 0.05 ether;
        uint256 actualAmount = engine.getNativeTokenAmountFromUsd(weth, usdAmount);

        assertEq(expectedAmount, actualAmount);
    }

    function test_depositRevertsWithUnapprovedCollateral() public {
        ERC20Mock karaToken = new ERC20Mock("Kara", "KARA", USER, 100e18);

        vm.startPrank(USER);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__TokenNotAllowed.selector, address(karaToken)));
        engine.depositCollateral(address(karaToken), 100e18);
        vm.stopPrank();
    }

    function test_canDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDSCMinted, uint256 collateralValueInUSD) = engine.getUserInformation(USER);

        uint256 expectedTotakDSCMinted = 0;
        uint256 expectedDepositAmount = engine.getNativeTokenAmountFromUsd(weth, collateralValueInUSD);

        assertEq(expectedTotakDSCMinted, totalDSCMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
    }

    function test_canDepositWithoutMinting() public depositedCollateral {
        uint256 userDscBalance = dsc.balanceOf(USER);
        assertEq(userDscBalance, 0);
    }

    function test_revertIfMintedDscBreaksHealthFactor() public {
        uint256 amountDscToMint = 90000e18; // to ensure that health factor is below 1

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__BelowMinimumHealthFactor.selector);
        engine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountDscToMint);
        vm.stopPrank();
    }

    function test_revertIfMintAmountIsZero() public {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.mintDsc(0);
        vm.stopPrank();
    }

    function test_canMintDSC() public depositedCollateral {
        vm.startPrank(USER);
        engine.mintDsc(AMOUNT_DSC);

        uint256 userDscBalance = dsc.balanceOf(USER);

        assertEq(userDscBalance, AMOUNT_DSC);
        vm.stopPrank();
    }

    function test_revertIfBurnAmountIsZero() public {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.burnDsc(0);
        vm.stopPrank();
    }

    function test_cannotBurnMoreThanBalance() public {
        vm.startPrank(USER);
        vm.expectRevert();
        engine.burnDsc(1);
        vm.stopPrank();
    }

    function test_canBurnDSC() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(engine), AMOUNT_DSC);
        engine.burnDsc(AMOUNT_DSC);
        vm.stopPrank();

        uint256 userDscBalance = dsc.balanceOf(USER);
        assertEq(userDscBalance, 0);
    }
}
