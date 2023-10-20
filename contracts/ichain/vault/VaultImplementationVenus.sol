// SPDX-License-Identifier: MIT

pragma solidity >=0.8.0 <0.9.0;

import './IVenusComptroller.sol';
import './IVenusMarket.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '../../library/ETHAndERC20.sol';
import '../../library/SafeMath.sol';
import './VaultStorage.sol';

/**
 * @title Venus Protocol Vault Implementation
 * @dev This contract serves as a vault for managing deposits within the Venus protocol.
 */
contract VaultImplementationVenus is VaultStorage {

    using SafeERC20 for IERC20;
    using ETHAndERC20 for address;
    using SafeMath for uint256;

    error OnlyGateway();
    error NotMarket();
    error InvalidMarket();
    error InvalidAsset();
    error EnterMarketError();
    error ExitMarketError();
    error DepositError();
    error RedeemError();

    uint256 constant UONE = 1e18;
    address constant assetETH = address(1);

    address public immutable gateway;
    address public immutable asset;       // Underlying asset, e.g. BUSD
    address public immutable market;      // Venus market, e.g. vBUSD
    address public immutable comptroller; // Venus comptroller
    address public immutable rewardToken; // Venus reward token, e.g. XVS

    modifier _onlyGateway_() {
        if (msg.sender != gateway) {
            revert OnlyGateway();
        }
        _;
    }

    constructor (
        address gateway_,
        address asset_,
        address market_,
        address comptroller_,
        address rewardToken_
    ) {
        if (!IVenusMarket(market_).isVToken()) {
            revert NotMarket();
        }
        if (
            asset_ == assetETH &&
            keccak256(abi.encodePacked(IVenusMarket(market_).symbol())) != keccak256('vBNB')
        ) {
            revert InvalidMarket();
        }
        if (asset_ != assetETH && IVenusMarket(market_).underlying() != asset_) {
            revert InvalidAsset();
        }

        gateway = gateway_;
        asset = asset_;
        market = market_;
        comptroller = comptroller_;
        rewardToken = rewardToken_;
    }

    function enterMarket() external _onlyAdmin_ {
        asset.approveMax(market);
        address[] memory markets = new address[](1);
        markets[0] = market;
        uint256[] memory errors = IVenusComptroller(comptroller).enterMarkets(markets);
        if (errors[0] != 0) {
            revert EnterMarketError();
        }
    }

    function exitMarket() external _onlyAdmin_ {
        asset.unapprove(market);
        uint256 error = IVenusComptroller(comptroller).exitMarket(market);
        if (error != 0) {
            revert ExitMarketError();
        }
    }

    function claimReward(address to) external _onlyAdmin_ {
        IVenusComptroller(comptroller).claimVenus(address(this));
        uint256 amount = rewardToken.balanceOfThis();
        if (amount > 0) {
            IERC20(rewardToken).safeTransfer(to, amount);
        }
    }

    // @notice Get the asset token balance belonging to a specific 'dTokenId'
    function getBalance(uint256 dTokenId) external view returns (uint256 balance) {
        uint256 stAmount = stAmounts[dTokenId];
        if (stAmount != 0) {
            // mAmount is the market token (e.g. vBUSD) balance associated with dTokenId
            uint256 mAmount = market.balanceOfThis() * stAmount / stTotalAmount;
            // Venus exchange rate which convert market amount to asset amount, e.g. vBUSD to BUSD
            uint256 exRate = IVenusMarket(market).exchangeRateStored();
            // Balance in asset, e.g. BUSD
            balance = exRate * mAmount / UONE;
        }
    }

    /**
     * @notice Deposit assets into the vault associated with a specific 'dTokenId'.
     * @param dTokenId The unique identifier of the dToken.
     * @param amount The amount of assets to deposit.
     * @return mintedSt The amount of staked tokens ('mintedSt') received in exchange for the deposited assets.
     */
    function deposit(uint256 dTokenId, uint256 amount) external payable _onlyGateway_ returns (uint256 mintedSt) {
        uint256 m1 = market.balanceOfThis();
        if (asset == assetETH) {
            IVenusMarket(market).mint{value: msg.value}();
        } else {
            asset.transferIn(gateway, amount);
            uint256 error = IVenusMarket(market).mint(amount);
            if (error != 0) {
                revert DepositError();
            }
        }
        uint256 m2 = market.balanceOfThis();

        // Calculate the 'mintedSt' based on changes in the market balance and staked amount ratios
        // `mintedSt` is in 18 decimals
        mintedSt = m1 == 0
            ? m2.rescale(market.decimals(), 18)
            : (m2 - m1) * stTotalAmount / m1;

        // Update the staked amount for 'dTokenId' and the total staked amount
        stAmounts[dTokenId] += mintedSt;
        stTotalAmount += mintedSt;
    }

    /**
     * @notice Redeem staked tokens and receive assets from the vault associated with a specific 'dTokenId.'
     * @param dTokenId The unique identifier of the dToken.
     * @param amount The amount of asset to redeem.
     * @return redeemedAmount The amount of assets received.
     */
    function redeem(uint256 dTokenId, uint256 amount) external _onlyGateway_ returns (uint256 redeemedAmount) {
        uint256 m1 = market.balanceOfThis();
        uint256 a1 = asset.balanceOfThis();

        uint256 stAmount = stAmounts[dTokenId];
        uint256 stTotal = stTotalAmount;
        uint256 mAmount = m1 * stAmount / stTotal;

        {
            // Calculate the market token amount ('mAmount') and available assets ('available') for redemption
            uint256 exRate = IVenusMarket(market).exchangeRateStored();
            uint256 available = exRate * mAmount / UONE;

            uint256 error;
            if (amount >= available) {
                // Redeem market tokens directly
                error = IVenusMarket(market).redeem(mAmount);
            } else {
                // Redeem underlying assets to cover the requested 'amount'
                error = IVenusMarket(market).redeemUnderlying(amount);
            }
            if (error != 0) {
                revert RedeemError();
            }
        }

        uint256 m2 = market.balanceOfThis();
        uint256 a2 = asset.balanceOfThis();

        // Calculate the staked tokens burned ('burnedSt') based on the change in market balances and staked amount ratios
        uint256 burnedSt = m1 - m2 == mAmount
            ? stAmount
            : ((m1 - m2) * stTotal).divRoundingUp(m1);

        // Update the staked amount for 'dTokenId' and the total staked amount
        stAmounts[dTokenId] -= burnedSt;
        stTotalAmount -= burnedSt;

        // Calculate the actual 'redeemedAmount' by subtracting initial and final asset balances
        redeemedAmount = a2 - a1;
        asset.transferOut(gateway, redeemedAmount);
    }

}
