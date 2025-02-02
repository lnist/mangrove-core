// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.10;

/**
 * @title IPriceOracleGetter
 * @author Aave
 * @notice Interface for the Aave price oracle.
 *
 */
interface IPriceOracleGetter {
  /**
   * @notice Returns the base currency address
   * @dev Address 0x0 is reserved for USD as base currency.
   * @return Returns the base currency address.
   *
   */
  function BASE_CURRENCY() external view returns (address);

  /**
   * @notice Returns the base currency unit
   * @dev 1 ether for ETH, 1e8 for USD.
   * @return Returns the base currency unit.
   *
   */
  function BASE_CURRENCY_UNIT() external view returns (uint);

  /**
   * @notice Returns the asset price in the base currency
   * @param asset The address of the asset
   * @return The price of the asset
   *
   */
  function getAssetPrice(address asset) external view returns (uint);

  /**
   * mangrove edit - missing in the originial interface
   * @notice Returns the assets prices in the base currency.
   * @param assets The addresses of the assets
   * @return prices of the asset
   *
   */
  function getAssetsPrices(address[] calldata assets) external view returns (uint[] memory prices);
}
