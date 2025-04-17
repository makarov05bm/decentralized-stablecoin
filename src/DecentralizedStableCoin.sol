// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @author  18Kara
 * @title   Decentralized Stable Coin
 * Collateral: Exogenous (ETC & BTC)
 * Minting: Algorithmic
 * Relative Stability: Pegged to USD
 * @dev     This contract is an ERC-20 implementation of the stablecoin
 * @notice  This contract is meant to be governed by DSCEngine => Ownable
 */
contract DecentralizedStableCoin is ERC20Burnable, Ownable {
    error DecentralizedStableCoin__BurnAmountZeroOrLess();
    error DecentralizedStableCoin__BurnAmountExceedBalance();
    error DecentralizedStableCoin__NoMintToZeroAddress();

    constructor() ERC20("DecentralizedStableCoin", "DSC") Ownable(msg.sender) {}

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);

        if (_amount <= 0) {
            revert DecentralizedStableCoin__BurnAmountZeroOrLess();
        }

        if (balance < _amount) {
            revert DecentralizedStableCoin__BurnAmountExceedBalance();
        }

        super.burn(_amount); // we used super because we are overrding the function
    }

    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert DecentralizedStableCoin__NoMintToZeroAddress();
        }

        if (_amount <= 0) {
            revert DecentralizedStableCoin__BurnAmountZeroOrLess();
        }

        _mint(_to, _amount);
        return true;
    }
}
