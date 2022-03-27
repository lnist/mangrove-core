// SPDX-License-Identifier:	BSD-2-Clause

//AaveLender.sol

// Copyright (c) 2021 Giry SAS. All rights reserved.

// Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

// 1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

pragma solidity ^0.8.10;
pragma abicoder v2;
import "../interfaces/aave/V3/IPool.sol";
import {IPoolAddressesProvider} from "../interfaces/aave/V3/IPoolAddressesProvider.sol";
import "../interfaces/aave/V3/IPriceOracleGetter.sol";
import {ReserveConfiguration as RC} from "../lib/aave/V3/ReserveConfiguration.sol";
import "../interfaces/IMangrove.sol";
import "../interfaces/IEIP20.sol";

//import "hardhat/console.sol";

contract AaveV3Module {
  event ErrorOnRedeem(
    address indexed outbound_tkn,
    address indexed inbound_tkn,
    uint indexed offerId,
    uint amount,
    string errorCode
  );
  event ErrorOnMint(
    address indexed outbound_tkn,
    address indexed inbound_tkn,
    uint indexed offerId,
    uint amount,
    string errorCode
  );

  // address of the lendingPool
  IPool public immutable lendingPool;
  IPriceOracleGetter public immutable priceOracle;
  uint16 referralCode;

  constructor(address _addressesProvider, uint _referralCode) {
    require(
      uint16(_referralCode) == _referralCode,
      "Referral code should be uint16"
    );

    referralCode = uint16(referralCode); // for aave reference, put 0 for tests

    address _priceOracle = IPoolAddressesProvider(_addressesProvider)
      .getAddress("PRICE_ORACLE");

    address _lendingPool = IPoolAddressesProvider(_addressesProvider).getPool();

    require(_lendingPool != address(0), "Invalid lendingPool address");
    require(_priceOracle != address(0), "Invalid priceOracle address");
    lendingPool = IPool(_lendingPool);
    priceOracle = IPriceOracleGetter(_priceOracle);
  }

  /**************************************************************************/
  ///@notice Required functions to let `this` contract interact with Aave
  /**************************************************************************/

  ///@notice approval of overlying contract by the underlying is necessary for minting and repaying borrow
  ///@notice user must use this function to do so.
  function approveLender(address token, uint amount) public {
    IEIP20(token).approve(address(lendingPool), amount);
  }

  ///@notice exits markets
  function _exitMarket(IEIP20 underlying) internal {
    lendingPool.setUserUseReserveAsCollateral(address(underlying), false);
  }

  function _enterMarkets(IEIP20[] calldata underlyings) internal {
    for (uint i = 0; i < underlyings.length; i++) {
      lendingPool.setUserUseReserveAsCollateral(address(underlyings[i]), true);
    }
  }

  function overlying(IEIP20 asset) public view returns (IEIP20 aToken) {
    aToken = IEIP20(lendingPool.getReserveData(address(asset)).aTokenAddress);
  }

  // structs to avoir stack too deep in maxGettableUnderlying
  struct Underlying {
    uint ltv;
    uint liquidationThreshold;
    uint decimals;
    uint price;
  }

  struct Account {
    uint collateral;
    uint debt;
    uint borrowPower;
    uint redeemPower;
    uint ltv;
    uint liquidationThreshold;
    uint health;
    uint balanceOfUnderlying;
  }

  /// @notice Computes maximal maximal redeem capacity (R) and max borrow capacity (B|R) after R has been redeemed
  /// returns (R, B|R)

  function maxGettableUnderlying(
    address asset,
    bool tryBorrow,
    address onBehalf
  ) public view returns (uint, uint) {
    Underlying memory underlying; // asset parameters
    Account memory account; // accound parameters
    (
      account.collateral,
      account.debt,
      account.borrowPower, // avgLtv * sumCollateralEth - sumDebtEth
      account.liquidationThreshold,
      account.ltv,
      account.health // avgLiquidityThreshold * sumCollateralEth / sumDebtEth  -- should be less than 10**18
    ) = lendingPool.getUserAccountData(onBehalf);
    DataTypes.ReserveData memory reserveData = lendingPool.getReserveData(
      asset
    );
    (
      underlying.ltv, // collateral factor for lending
      underlying.liquidationThreshold, // collateral factor for borrowing
      ,
      /*liquidationBonus*/
      underlying.decimals,
      /*reserveFactor*/
      /*emode_category*/
      ,

    ) = RC.getParams(reserveData.configuration);
    account.balanceOfUnderlying = IEIP20(reserveData.aTokenAddress).balanceOf(
      onBehalf
    );

    underlying.price = priceOracle.getAssetPrice(asset); // divided by 10**underlying.decimals

    // account.redeemPower = account.liquidationThreshold * account.collateral - account.debt
    account.redeemPower =
      (account.liquidationThreshold * account.collateral) /
      10**4 -
      account.debt;
    // max redeem capacity = account.redeemPower/ underlying.liquidationThreshold * underlying.price
    // unless account doesn't have enough collateral in asset token (hence the min())

    uint maxRedeemableUnderlying = (account.redeemPower * // in 10**underlying.decimals
        10**(underlying.decimals) *
        10**4) / (underlying.liquidationThreshold * underlying.price);

    maxRedeemableUnderlying = (maxRedeemableUnderlying <
      account.balanceOfUnderlying)
      ? maxRedeemableUnderlying
      : account.balanceOfUnderlying;

    if (!tryBorrow) {
      //gas saver
      return (maxRedeemableUnderlying, 0);
    }
    // computing max borrow capacity on the premisses that maxRedeemableUnderlying has been redeemed.
    // max borrow capacity = (account.borrowPower - (ltv*redeemed)) / underlying.ltv * underlying.price

    uint borrowPowerImpactOfRedeemInUnderlying = (maxRedeemableUnderlying *
      underlying.ltv) / 10**4;

    uint borrowPowerInUnderlying = (account.borrowPower *
      10**underlying.decimals) / underlying.price;

    if (borrowPowerImpactOfRedeemInUnderlying > borrowPowerInUnderlying) {
      // no more borrowPower left after max redeem operation
      return (maxRedeemableUnderlying, 0);
    }

    // max borrow power in underlying after max redeem has been withdrawn
    uint maxBorrowAfterRedeemInUnderlying = borrowPowerInUnderlying -
      borrowPowerImpactOfRedeemInUnderlying;

    return (maxRedeemableUnderlying, maxBorrowAfterRedeemInUnderlying);
  }

  function aaveRedeem(
    uint amountToRedeem,
    address onBehalf,
    ML.SingleOrder calldata order
  ) internal returns (uint) {
    try
      lendingPool.withdraw(order.outbound_tkn, amountToRedeem, onBehalf)
    returns (uint withdrawn) {
      //aave redeem was a success
      if (amountToRedeem == withdrawn) {
        return 0;
      } else {
        return (amountToRedeem - withdrawn);
      }
    } catch Error(string memory message) {
      emit ErrorOnRedeem(
        order.outbound_tkn,
        order.inbound_tkn,
        order.offerId,
        amountToRedeem,
        message
      );
      return amountToRedeem;
    }
  }

  function _mint(
    uint amount,
    address token,
    address onBehalf
  ) internal {
    lendingPool.deposit(token, amount, onBehalf, referralCode);
  }

  // adapted from https://medium.com/compound-finance/supplying-assets-to-the-compound-protocol-ec2cf5df5aa#afff
  // utility to supply erc20 to compound
  // NB `ctoken` contract MUST be approved to perform `transferFrom token` by `this` contract.
  /// @notice user need to approve ctoken in order to mint
  function aaveMint(
    uint amount,
    address onBehalf,
    ML.SingleOrder calldata order
  ) internal returns (uint) {
    // contract must haveallowance()to spend funds on behalf ofmsg.sender for at-leastamount for the asset being deposited. This can be done via the standard ERC20 approve() method.
    try lendingPool.deposit(order.inbound_tkn, amount, onBehalf, referralCode) {
      return 0;
    } catch Error(string memory message) {
      emit ErrorOnMint(
        order.outbound_tkn,
        order.inbound_tkn,
        order.offerId,
        amount,
        message
      );
    } catch {
      emit ErrorOnMint(
        order.outbound_tkn,
        order.inbound_tkn,
        order.offerId,
        amount,
        "unexpected"
      );
    }
    return amount;
  }
}
