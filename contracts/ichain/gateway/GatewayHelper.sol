// SPDX-License-Identifier: MIT

pragma solidity >=0.8.0 <0.9.0;

import '../vault/IVault.sol';
import '../token/IDToken.sol';
import '../token/IIOU.sol';
import '../../oracle/IOracle.sol';
import '../swapper/ISwapper.sol';
import './IGateway.sol';
import '../liqclaim/ILiqClaim.sol';
import '../../library/Bytes32Map.sol';
import '../../library/ETHAndERC20.sol';
import '../../library/SafeMath.sol';
import '@openzeppelin/contracts/utils/cryptography/ECDSA.sol';
import { GatewayIndex as I } from './GatewayIndex.sol';

library GatewayHelper {

    using Bytes32Map for mapping(uint8 => bytes32);
    using ETHAndERC20 for address;
    using SafeMath for uint256;
    using SafeMath for int256;

    error CannotDelBToken();
    error BTokenDupInitialize();
    error BTokenNoSwapper();
    error BTokenNoOracle();
    error InvalidBToken();
    error InvalidSignature();

    event AddBToken(address bToken, address vault, bytes32 oracleId, uint256 collateralFactor);

    event DelBToken(address bToken);

    event UpdateBToken(address bToken);

    event SetExecutionFee(uint256 actionId, uint256 executionFee);

    event FinishCollectProtocolFee(
        uint256 amount
    );

    uint256 constant UONE = 1e18;
    address constant tokenETH = address(1);

    //================================================================================
    // Getters
    //================================================================================

    function getGatewayState(mapping(uint8 => bytes32) storage gatewayStates)
    external view returns (IGateway.GatewayState memory s)
    {
        s.cumulativePnlOnGateway = gatewayStates.getInt(I.S_CUMULATIVEPNLONGATEWAY);
        s.liquidityTime = gatewayStates.getUint(I.S_LIQUIDITYTIME);
        s.totalLiquidity = gatewayStates.getUint(I.S_TOTALLIQUIDITY);
        s.cumulativeTimePerLiquidity = gatewayStates.getInt(I.S_CUMULATIVETIMEPERLIQUIDITY);
        s.gatewayRequestId = gatewayStates.getUint(I.S_GATEWAYREQUESTID);
        s.dChainExecutionFeePerRequest = gatewayStates.getUint(I.S_DCHAINEXECUTIONFEEPERREQUEST);
        s.totalIChainExecutionFee = gatewayStates.getUint(I.S_TOTALICHAINEXECUTIONFEE);
        s.cumulativeCollectedProtocolFee = gatewayStates.getUint(I.S_CUMULATIVECOLLECTEDPROTOCOLFEE);
    }

    function getBTokenState(
        mapping(address => mapping(uint8 => bytes32)) storage bTokenStates,
        address bToken
    ) external view returns (IGateway.BTokenState memory s)
    {
        s.vault = bTokenStates[bToken].getAddress(I.B_VAULT);
        s.oracleId = bTokenStates[bToken].getBytes32(I.B_ORACLEID);
        s.collateralFactor = bTokenStates[bToken].getUint(I.B_COLLATERALFACTOR);
    }

    function getLpState(
        mapping(address => mapping(uint8 => bytes32)) storage bTokenStates,
        mapping(uint256 => mapping(uint8 => bytes32)) storage dTokenStates,
        uint256 lTokenId
    ) external view returns (IGateway.LpState memory s)
    {
        s.requestId = dTokenStates[lTokenId].getUint(I.D_REQUESTID);
        s.bToken = dTokenStates[lTokenId].getAddress(I.D_BTOKEN);
        s.bAmount = IVault(bTokenStates[s.bToken].getAddress(I.B_VAULT)).getBalance(lTokenId);
        s.b0Amount = dTokenStates[lTokenId].getInt(I.D_B0AMOUNT);
        s.lastCumulativePnlOnEngine = dTokenStates[lTokenId].getInt(I.D_LASTCUMULATIVEPNLONENGINE);
        s.liquidity = dTokenStates[lTokenId].getUint(I.D_LIQUIDITY);
        s.cumulativeTime = dTokenStates[lTokenId].getUint(I.D_CUMULATIVETIME);
        s.lastCumulativeTimePerLiquidity = dTokenStates[lTokenId].getUint(I.D_LASTCUMULATIVETIMEPERLIQUIDITY);
        s.lastRequestIChainExecutionFee = dTokenStates[lTokenId].getUint(I.D_LASTREQUESTICHAINEXECUTIONFEE);
        s.cumulativeUnusedIChainExecutionFee = dTokenStates[lTokenId].getUint(I.D_CUMULATIVEUNUSEDICHAINEXECUTIONFEE);
    }

    function getTdState(
        mapping(address => mapping(uint8 => bytes32)) storage bTokenStates,
        mapping(uint256 => mapping(uint8 => bytes32)) storage dTokenStates,
        uint256 pTokenId
    ) external view returns (IGateway.TdState memory s)
    {
        s.requestId = dTokenStates[pTokenId].getUint(I.D_REQUESTID);
        s.bToken = dTokenStates[pTokenId].getAddress(I.D_BTOKEN);
        s.bAmount = IVault(bTokenStates[s.bToken].getAddress(I.B_VAULT)).getBalance(pTokenId);
        s.b0Amount = dTokenStates[pTokenId].getInt(I.D_B0AMOUNT);
        s.lastCumulativePnlOnEngine = dTokenStates[pTokenId].getInt(I.D_LASTCUMULATIVEPNLONENGINE);
        s.singlePosition = dTokenStates[pTokenId].getBool(I.D_SINGLEPOSITION);
        s.lastRequestIChainExecutionFee = dTokenStates[pTokenId].getUint(I.D_LASTREQUESTICHAINEXECUTIONFEE);
        s.cumulativeUnusedIChainExecutionFee = dTokenStates[pTokenId].getUint(I.D_CUMULATIVEUNUSEDICHAINEXECUTIONFEE);
    }

    function getCumulativeTime(
        mapping(uint8 => bytes32) storage gatewayStates,
        mapping(uint256 => mapping(uint8 => bytes32)) storage dTokenStates,
        uint256 lTokenId
    ) external view returns (uint256 cumulativeTimePerLiquidity, uint256 cumulativeTime)
    {
        uint256 liquidityTime = gatewayStates.getUint(I.S_LIQUIDITYTIME);
        uint256 totalLiquidity = gatewayStates.getUint(I.S_TOTALLIQUIDITY);
        cumulativeTimePerLiquidity = gatewayStates.getUint(I.S_CUMULATIVETIMEPERLIQUIDITY);
        uint256 liquidity = dTokenStates[lTokenId].getUint(I.D_LIQUIDITY);
        cumulativeTime = dTokenStates[lTokenId].getUint(I.D_CUMULATIVETIME);
        uint256 lastCumulativeTimePerLiquidity = dTokenStates[lTokenId].getUint(I.D_LASTCUMULATIVETIMEPERLIQUIDITY);

        if (totalLiquidity != 0) {
            uint256 diff1 = (block.timestamp - liquidityTime) * UONE * UONE / totalLiquidity;
            unchecked { cumulativeTimePerLiquidity += diff1; }

            if (liquidity != 0) {
                uint256 diff2;
                unchecked { diff2 = cumulativeTimePerLiquidity - lastCumulativeTimePerLiquidity; }
                cumulativeTime += diff2 * liquidity / UONE;
            }
        }
    }

    function getExecutionFees(mapping(uint256 => uint256) storage executionFees)
    external view returns (uint256[] memory fees)
    {
        fees = new uint256[](5);
        fees[0] = executionFees[I.ACTION_REQUESTADDLIQUIDITY];
        fees[1] = executionFees[I.ACTION_REQUESTREMOVELIQUIDITY];
        fees[2] = executionFees[I.ACTION_REQUESTREMOVEMARGIN];
        fees[3] = executionFees[I.ACTION_REQUESTTRADE];
        fees[4] = executionFees[I.ACTION_REQUESTTRADEANDREMOVEMARGIN];
    }

    //================================================================================
    // Setters
    //================================================================================

    function addBToken(
        mapping(address => mapping(uint8 => bytes32)) storage bTokenStates,
        ISwapper swapper,
        IOracle oracle,
        IVault vault0,
        address tokenB0,
        address bToken,
        address vault,
        bytes32 oracleId,
        uint256 collateralFactor
    ) external
    {
        if (bTokenStates[bToken].getAddress(I.B_VAULT) != address(0)) {
            revert BTokenDupInitialize();
        }
        if (IVault(vault).asset() != bToken) {
            revert InvalidBToken();
        }
        if (bToken != tokenETH) {
            if (!swapper.isSupportedToken(bToken)) {
                revert BTokenNoSwapper();
            }
            // Approve for swapper and vault
            bToken.approveMax(address(swapper));
            bToken.approveMax(vault);
            if (bToken == tokenB0) {
                // The reserved portion for B0 will be deposited to vault0
                bToken.approveMax(address(vault0));
            }
        }
        // Check bToken oracle except B0
        if (bToken != tokenB0 && oracle.getValue(oracleId) == 0) {
            revert BTokenNoOracle();
        }
        bTokenStates[bToken].set(I.B_VAULT, vault);
        bTokenStates[bToken].set(I.B_ORACLEID, oracleId);
        bTokenStates[bToken].set(I.B_COLLATERALFACTOR, collateralFactor);

        emit AddBToken(bToken, vault, oracleId, collateralFactor);
    }

    function delBToken(
        mapping(address => mapping(uint8 => bytes32)) storage bTokenStates,
        address bToken
    ) external
    {
        // bToken can only be deleted when there is no deposits
        if (IVault(bTokenStates[bToken].getAddress(I.B_VAULT)).stTotalAmount() != 0) {
            revert CannotDelBToken();
        }

        bTokenStates[bToken].del(I.B_VAULT);
        bTokenStates[bToken].del(I.B_ORACLEID);
        bTokenStates[bToken].del(I.B_COLLATERALFACTOR);

        emit DelBToken(bToken);
    }

    // @dev This function can be used to change bToken collateral factor
    function setBTokenParameter(
        mapping(address => mapping(uint8 => bytes32)) storage bTokenStates,
        address bToken,
        uint8 idx,
        bytes32 value
    ) external
    {
        bTokenStates[bToken].set(idx, value);
        emit UpdateBToken(bToken);
    }

    // @notice Set execution fee for actionId
    function setExecutionFee(
        mapping(uint256 => uint256) storage executionFees,
        uint256 actionId,
        uint256 executionFee
    ) external
    {
        executionFees[actionId] = executionFee;
        emit SetExecutionFee(actionId, executionFee);
    }

    function setDChainExecutionFeePerRequest(
        mapping(uint8 => bytes32) storage gatewayStates,
        uint256 dChainExecutionFeePerRequest
    ) external
    {
        gatewayStates.set(I.S_DCHAINEXECUTIONFEEPERREQUEST, dChainExecutionFeePerRequest);
    }

    // @notic Claim dChain executionFee to account `to`
    function claimDChainExecutionFee(
        mapping(uint8 => bytes32) storage gatewayStates,
        address to
    ) external
    {
        tokenETH.transferOut(to, tokenETH.balanceOfThis() - gatewayStates.getUint(I.S_TOTALICHAINEXECUTIONFEE));
    }

    // @notice Claim unused iChain execution fee for dTokenId
    function claimUnusedIChainExecutionFee(
        mapping(uint8 => bytes32) storage gatewayStates,
        mapping(uint256 => mapping(uint8 => bytes32)) storage dTokenStates,
        IDToken lToken,
        IDToken pToken,
        uint256 dTokenId,
        bool isLp
    ) external
    {
        address owner = isLp ? lToken.ownerOf(dTokenId) : pToken.ownerOf(dTokenId);
        uint256 cumulativeUnusedIChainExecutionFee = dTokenStates[dTokenId].getUint(I.D_CUMULATIVEUNUSEDICHAINEXECUTIONFEE);
        if (cumulativeUnusedIChainExecutionFee > 0) {
            uint256 totalIChainExecutionFee = gatewayStates.getUint(I.S_TOTALICHAINEXECUTIONFEE);
            totalIChainExecutionFee -= cumulativeUnusedIChainExecutionFee;
            gatewayStates.set(I.S_TOTALICHAINEXECUTIONFEE, totalIChainExecutionFee);

            dTokenStates[dTokenId].del(I.D_CUMULATIVEUNUSEDICHAINEXECUTIONFEE);

            tokenETH.transferOut(owner, cumulativeUnusedIChainExecutionFee);
        }
    }

    // @notice Redeem B0 for burning IOU
    function redeemIOU(
        address tokenB0,
        IVault vault0,
        IIOU iou,
        address to,
        uint256 b0Amount
    ) external {
        if (b0Amount > 0) {
            uint256 b0Redeemed = vault0.redeem(uint256(0), b0Amount);
            if (b0Redeemed > 0) {
                iou.burn(to, b0Redeemed);
                tokenB0.transferOut(to, b0Redeemed);
            }
        }
    }

    function verifyEventData(
        bytes memory eventData,
        bytes memory signature,
        uint256 eventDataLength,
        address dChainEventSigner
    ) external pure {
        require(eventData.length == eventDataLength, 'Wrong eventData length');
        bytes32 hash = ECDSA.toEthSignedMessageHash(keccak256(eventData));
        if (ECDSA.recover(hash, signature) != dChainEventSigner) {
            revert InvalidSignature();
        }
    }


    //================================================================================
    // Interactions
    //================================================================================

    function finishCollectProtocolFee(
        mapping(uint8 => bytes32) storage gatewayStates,
        IVault vault0,
        address tokenB0,
        address protocolFeeManager,
        uint256 cumulativeCollectedProtocolFeeOnEngine
    ) external {
        uint8 decimalsB0 = tokenB0.decimals();
        uint256 cumulativeCollectedProtocolFeeOnGateway = gatewayStates.getUint(I.S_CUMULATIVECOLLECTEDPROTOCOLFEE);
        if (cumulativeCollectedProtocolFeeOnEngine > cumulativeCollectedProtocolFeeOnGateway) {
            uint256 amount = (cumulativeCollectedProtocolFeeOnEngine - cumulativeCollectedProtocolFeeOnGateway).rescaleDown(18, decimalsB0);
            if (amount > 0) {
                amount = vault0.redeem(uint256(0), amount);
                tokenB0.transferOut(protocolFeeManager, amount);
                cumulativeCollectedProtocolFeeOnGateway += amount.rescale(decimalsB0, 18);
                gatewayStates.set(I.S_CUMULATIVECOLLECTEDPROTOCOLFEE, cumulativeCollectedProtocolFeeOnGateway);
                emit FinishCollectProtocolFee(
                    amount
                );
            }
        }
    }

    function liquidateRedeemAndSwap(
        uint8 decimalsB0,
        address bToken,
        address swapper,
        address liqClaim,
        address pToken,
        uint256 pTokenId,
        int256 b0Amount,
        uint256 bAmount,
        int256 maintenanceMarginRequired
    ) external returns (uint256) {
        uint256 b0AmountIn;

        // only swap needed B0 to cover maintenanceMarginRequired
        int256 requiredB0Amount = maintenanceMarginRequired.rescaleUp(18, decimalsB0) - b0Amount;
        if (requiredB0Amount > 0) {
            if (bToken == tokenETH) {
                (uint256 resultB0, uint256 resultBX) = ISwapper(swapper).swapETHForExactB0{value:bAmount}(requiredB0Amount.itou());
                b0AmountIn += resultB0;
                bAmount -= resultBX;
            } else {
                (uint256 resultB0, uint256 resultBX) = ISwapper(swapper).swapBXForExactB0(bToken, requiredB0Amount.itou(), bAmount);
                b0AmountIn += resultB0;
                bAmount -= resultBX;
            }
        }
        if (bAmount > 0) {
            bToken.transferOut(liqClaim, bAmount);
            ILiqClaim(liqClaim).registerDeposit(IDToken(pToken).ownerOf(pTokenId), bToken, bAmount);
        }

        return b0AmountIn;
    }

}
