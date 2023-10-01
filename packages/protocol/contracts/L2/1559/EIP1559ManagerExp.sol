// SPDX-License-Identifier: MIT
//  _____     _ _         _         _
// |_   _|_ _(_) |_____  | |   __ _| |__ ___
//   | |/ _` | | / / _ \ | |__/ _` | '_ (_-<
//   |_|\__,_|_|_\_\___/ |____\__,_|_.__/__/

pragma solidity ^0.8.20;

import { EssentialContract } from "../../common/EssentialContract.sol";
import { LibMath } from "../../libs/LibMath.sol";
import { LibFixedPointMath } from "../../thirdparty/LibFixedPointMath.sol";

import { EIP1559Manager } from "./EIP1559Manager.sol";

library Lib1559Exp {
    using LibMath for uint256;

    error EIP1559_OUT_OF_GAS();
    error EIP1559_UNEXPECTED_CHANGE(uint256, uint256);

    function calcBaseFeePerGas(
        uint256 gasIssuePerSecond,
        uint256 xscale,
        uint256 yscale,
        uint256 gasExcessMax,
        uint256 gasExcess,
        uint256 blockTime,
        uint256 gasToBuy
    )
        internal
        pure
        returns (uint256 _baseFeePerGas, uint256 _gasExcess)
    {
        uint256 issued = gasIssuePerSecond * blockTime;
        uint256 _gasExcessOld = gasExcess.max(issued) - issued;
        _gasExcess = _gasExcessOld + gasToBuy;

        if (_gasExcess > gasExcessMax) revert EIP1559_OUT_OF_GAS();

        _baseFeePerGas = _calculatePrice(xscale, yscale, _gasExcess, gasToBuy);
    }

    /// @dev Calculates xscale and yscale values used for pricing.
    /// @param xExcessMax The maximum excess value.
    /// @param price The current price.
    /// @param target The target gas value.
    /// @param ratio2x1x Expected ratio of gas price for two blocks.
    /// @return xscale Calculated x scale value.
    /// @return yscale Calculated y scale value.
    function calculateScales(
        uint256 xExcessMax,
        uint256 price,
        uint256 target,
        uint256 ratio2x1x
    )
        internal
        pure
        returns (uint256 xscale, uint256 yscale)
    {
        assert(xExcessMax != 0);
        uint256 x = xExcessMax / 2;

        // Calculate xscale
        xscale = LibFixedPointMath.MAX_EXP_INPUT / xExcessMax;

        // Calculate yscale
        yscale = _calculatePrice(xscale, price, x, target);

        // Verify the gas price ratio between two blocks, one has
        // target * 2 gas and the other one has target gas.
        uint256 price1x = _calculatePrice(xscale, yscale, x, target);
        uint256 price2x = _calculatePrice(xscale, yscale, x, target * 2);
        uint256 ratio = price2x * 10_000 / price1x;

        if (ratio2x1x != ratio) {
            revert EIP1559_UNEXPECTED_CHANGE(ratio2x1x, ratio);
        }
    }

    function _calculatePrice(
        uint256 xscale,
        uint256 yscale,
        uint256 gasExcess,
        uint256 gasToBuy
    )
        private
        pure
        returns (uint256)
    {
        uint256 _gasToBuy = gasToBuy == 0 ? 1 : gasToBuy;
        uint256 _before = _calcY(gasExcess, xscale);
        uint256 _after = _calcY(gasExcess + _gasToBuy, xscale);
        return (_after - _before) / _gasToBuy / yscale;
    }

    function _calcY(uint256 x, uint256 xscale) private pure returns (uint256) {
        uint256 _x = x * xscale;
        if (_x >= LibFixedPointMath.MAX_EXP_INPUT) {
            revert EIP1559_OUT_OF_GAS();
        }
        return uint256(LibFixedPointMath.exp(int256(_x)));
    }
}

/// @title EIP1559ManagerExp
/// @notice Contract that implements EIP-1559 using
/// https://ethresear.ch/t/make-eip-1559-more-like-an-amm-curve/9082
contract EIP1559ManagerExp is EssentialContract, EIP1559Manager {
    using LibMath for uint256;

    uint256 public constant X_SCALE = 1_488_514_844;
    uint256 public constant Y_SCALE = 358_298_803_609_133_338_138_868_404_779;
    uint256 public constant GAS_ISSUE_PER_SECOND = 12_500_000;
    uint64 public constant MAX_GAS_EXCESS = 90_900_000_000;

    uint128 public gasExcess;
    uint64 public parentTimestamp;
    uint256[49] private __gap;

    /// @notice Initializes the TaikoL2 contract.
    function init(address _addressManager) external initializer {
        EssentialContract._init(_addressManager);
        gasExcess = MAX_GAS_EXCESS / 2;
        parentTimestamp = uint64(block.timestamp);

        emit BaseFeeUpdated(calcBaseFeePerGas(1));
    }

    /// @inheritdoc EIP1559Manager
    function updateBaseFeePerGas(uint32 gasUsed)
        external
        onlyFromNamed("taiko")
        returns (uint64 baseFeePerGas)
    {
        uint256 _baseFeePerGas;
        uint256 _gasExcess;
        (_baseFeePerGas, _gasExcess) = Lib1559Exp.calcBaseFeePerGas({
            gasIssuePerSecond: GAS_ISSUE_PER_SECOND,
            xscale: X_SCALE,
            yscale: Y_SCALE,
            gasExcessMax: MAX_GAS_EXCESS,
            gasExcess: gasExcess,
            blockTime: block.timestamp - parentTimestamp,
            gasToBuy: gasUsed
        });

        parentTimestamp = uint64(block.timestamp);
        gasExcess = uint128(_gasExcess.min(type(uint128).max));
        baseFeePerGas = uint64(_baseFeePerGas.min(type(uint64).max));

        emit BaseFeeUpdated(baseFeePerGas);
    }

    /// @inheritdoc EIP1559Manager
    function calcBaseFeePerGas(uint32 gasUsed) public view returns (uint64) {
        (uint256 _baseFeePerGas,) = Lib1559Exp.calcBaseFeePerGas({
            gasIssuePerSecond: GAS_ISSUE_PER_SECOND,
            xscale: X_SCALE,
            yscale: Y_SCALE,
            gasExcessMax: MAX_GAS_EXCESS,
            gasExcess: gasExcess,
            blockTime: block.timestamp - parentTimestamp,
            gasToBuy: gasUsed
        });

        return uint64(_baseFeePerGas.min(type(uint64).max));
    }
}
