//SPDX-Licence-Identifier: MIT
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {ERC20Mock} from
    "@chainlink/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract Handler is Test {
    DSCEngine engine;
    DecentralizedStableCoin dsc;

    uint256 constant MAX_DEPOSIT_SIZE = type(uint96).max;
    uint256 public mintCalled;

    address[] public usersWithCollateralDeposited;

    MockV3Aggregator public ethUsdPriceFeed;

    constructor(DSCEngine _engine, DecentralizedStableCoin _dsc) {
        engine = _engine;
        dsc = _dsc;

        ethUsdPriceFeed = MockV3Aggregator(engine.getCollateralTokenPriceFeed(engine.getCollateralTokens()[0]));
    }

    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) external {
        address collateral = _getCollateralFromSeed(collateralSeed);
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);

        vm.startPrank(msg.sender);
        ERC20Mock(collateral).mint(msg.sender, amountCollateral);
        ERC20Mock(collateral).approve(address(engine), amountCollateral);
        engine.depositCollateral(collateral, amountCollateral);
        vm.stopPrank();

        usersWithCollateralDeposited.push(msg.sender);
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) external {
        address collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxCollateralToRedeedm = engine.getCollateralBalanceOfUser(msg.sender, collateral);

        amountCollateral = bound(amountCollateral, 0, maxCollateralToRedeedm);

        vm.assume(amountCollateral > 0);
        engine.redeemCollateral(collateral, amountCollateral);
    }

    function mintDSC(uint256 amount, uint256 addressSeed) external {
        address sender = usersWithCollateralDeposited[addressSeed % usersWithCollateralDeposited.length];
        (uint256 totalDSCMinted, uint256 collateralValueInUSD) = engine.getUserInformation(sender);

        // Ensure that the health factor does not break
        int256 maxDscToMint = (int256(collateralValueInUSD) / 2) - int256(totalDSCMinted);
        vm.assume(maxDscToMint > 0);

        amount = bound(amount, 0, uint256(maxDscToMint));
        vm.assume(amount > 0);

        vm.startPrank(sender);
        engine.mintDsc(amount);
        vm.stopPrank();
        mintCalled++;
    }

    function updateCollateralPrice(uint96 newPrice) public {
        int256 newPriceInt = int256(uint256(newPrice));
        ethUsdPriceFeed.updateAnswer(newPriceInt);
    }

    // Helper Functions
    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (address) {
        if (collateralSeed % 2 == 0) {
            return engine.getCollateralTokens()[0];
        } else {
            return engine.getCollateralTokens()[1];
        }
    }
}
