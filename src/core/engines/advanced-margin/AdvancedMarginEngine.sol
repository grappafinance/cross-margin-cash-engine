// SPDX-License-Identifier: MIT
pragma solidity =0.8.13;

// imported contracts and libraries
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {SafeERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {Ownable} from "openzeppelin/access/Ownable.sol";

// interfaces
import {IOracle} from "../../../interfaces/IOracle.sol";
import {IGrappa} from "../../../interfaces/IGrappa.sol";
import {IMarginEngine} from "../../../interfaces/IMarginEngine.sol";
import {IVolOracle} from "../../../interfaces/IVolOracle.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";

// librarise
import {TokenIdUtil} from "../../../libraries/TokenIdUtil.sol";
import {NumberUtil} from "../../../libraries/NumberUtil.sol";
import {AdvancedMarginMath} from "./AdvancedMarginMath.sol";
import {AdvancedMarginLib} from "./AdvancedMarginLib.sol";

// constants and types
import "../../../config/types.sol";
import "../../../config/enums.sol";
import "../../../config/constants.sol";
import "../../../config/errors.sol";

/**
 * @title   AdvancedMarginEngine
 * @author  @antoncoding
 * @notice  AdvancedMarginEngine is in charge of maintaining margin requirement for partial collateralized options
            Please see AdvancedMarginMath.sol for detailed partial collat calculation
            Interacts with VolOracle to read vol
            Listen to calls from Grappa to update accountings
 */
contract AdvancedMarginEngine is IMarginEngine, Ownable {
    using AdvancedMarginMath for AdvancedMarginDetail;
    using AdvancedMarginLib for Account;
    using SafeERC20 for IERC20;
    using FixedPointMathLib for uint256;
    using NumberUtil for uint256;

    IGrappa public immutable grappa;
    IOracle public immutable oracle;
    IVolOracle public immutable volOracle;

    /*///////////////////////////////////////////////////////////////
                                  Variables
    //////////////////////////////////////////////////////////////*/

    ///@dev subAccount => Account structure.
    ///     subAccount can be an address similar to the primary account, but has the last 8 bits different.
    ///     this give every account access to 256 sub-accounts
    mapping(address => Account) public marginAccounts;

    ///@dev mapping of productId to AdvancedMargin Parameters
    mapping(uint32 => ProductMarginParams) public productParams;

    // solhint-disable-next-line no-empty-blocks
    constructor(
        address _grappa,
        address _oracle,
        address _volOracle
    ) {
        grappa = IGrappa(_grappa);
        oracle = IOracle(_oracle);
        volOracle = IVolOracle(_volOracle);
    }

    /*///////////////////////////////////////////////////////////////
                                  Events
    //////////////////////////////////////////////////////////////*/
    event ProductConfigurationUpdated(
        uint32 productId,
        uint32 dUpper,
        uint32 dLower,
        uint32 rUpper,
        uint32 rLower,
        uint32 volMul
    );

    /*///////////////////////////////////////////////////////////////
                        External Functions
    //////////////////////////////////////////////////////////////*/

    /**
     * todo: consider moving this to viewer contract
     * @notice get minimum collateral needed for a margin account
     * @param _subAccount account id.
     * @return minCollateral minimum collateral required, in collateral asset's decimals
     */
    function getMinCollateral(address _subAccount) external view returns (uint256 minCollateral) {
        Account memory account = marginAccounts[_subAccount];
        AdvancedMarginDetail memory detail = _getAccountDetail(account);

        minCollateral = _getMinCollateral(detail);
    }

    function isAccountHealthy(address _subAccount) external view returns (bool) {
        return _isAccountHealthy(marginAccounts[_subAccount]);
    }

    /**
     * @notice  liquidate an account:
     *          burning the token the account is shorted (repay the debt),
     *          and get the collateral from the margin account.
     * @dev     expected to be called by liquidators
     * @param _subAccount account to liquidate
     * @param _liquidator the account calling liquidate on Grappa
     * @param tokensToBurn arrays of token burned
     * @param amountsToBurn amounts burned
     */
    function liquidate(
        address _subAccount,
        address _liquidator,
        uint256[] memory tokensToBurn,
        uint256[] memory amountsToBurn
    ) external returns (address collateral, uint80 collateralToPay) {
        _assertCallerIsGrappa();

        uint256 repayCallAmount = amountsToBurn[0];
        uint256 repayPutAmount = amountsToBurn[1];

        Account memory account = marginAccounts[_subAccount];

        if (account.shortCallId != tokensToBurn[0]) revert AM_WrongIdToLiquidate();
        if (account.shortPutId != tokensToBurn[1]) revert AM_WrongIdToLiquidate();

        if (_isAccountHealthy(account)) revert AM_AccountIsHealthy();

        bool hasShortCall = account.shortCallAmount != 0;
        bool hasShortPut = account.shortPutAmount != 0;

        // compute portion of the collateral the liquidator is repaying, in BPS.
        // @note: expected to lost precision becuase of performing division before multiplication
        uint256 portionBPS;
        if (hasShortCall && hasShortPut) {
            // if the account is short call and put at the same time,
            // amounts to liquidate needs to be the same portion of short call and short put amount.
            uint256 callPortionBPS = (repayCallAmount * BPS) / account.shortCallAmount;
            uint256 putPortionBPS = (repayPutAmount * BPS) / account.shortPutAmount;
            if (callPortionBPS != putPortionBPS) revert AM_WrongRepayAmounts();
            portionBPS = callPortionBPS;
        } else if (hasShortCall) {
            // account only short call
            if (repayPutAmount != 0) revert AM_WrongRepayAmounts();
            portionBPS = (repayCallAmount * BPS) / account.shortCallAmount;
        } else {
            // if account is underwater, it must have shortCall or shortPut. in this branch it will sure have shortPutAmount > 0;
            // account only short put
            if (repayCallAmount != 0) revert AM_WrongRepayAmounts();
            portionBPS = (repayPutAmount * BPS) / account.shortPutAmount;
        }

        // update account's debt and perform "safe" external calls
        if (hasShortCall) {
            account.burnOptionMemory(account.shortCallId, uint64(repayCallAmount));
        }
        if (hasShortPut) {
            // cacheShortPutId = account.shortPutId;
            account.burnOptionMemory(account.shortPutId, uint64(repayPutAmount));
        }

        // update account's collateral
        // address collateral = grappa.assets(account.collateralId);
        collateralToPay = uint80((account.collateralAmount * portionBPS) / BPS);

        collateral = grappa.assets(account.collateralId).addr;

        // if liquidator is trying to remove more collateral than owned, this line will revert
        account.removeCollateralMemory(collateralToPay);

        // write new accout to storage
        marginAccounts[_subAccount] = account;

        IERC20(collateral).safeTransfer(_liquidator, collateralToPay);
    }

    /**
     * @notice payout to user on settlement.
     * @dev this can only triggered by Grappa, would only be called on settlement.
     * @param _asset asset to transfer
     * @param _recipient receiber
     * @param _amount amount
     */
    function payCashValue(
        address _asset,
        address _recipient,
        uint256 _amount
    ) external {
        _assertCallerIsGrappa();

        IERC20(_asset).safeTransfer(_recipient, _amount);
    }

    /**
     * @notice  move an account to someone else
     * @dev     expected to be call by account owner
     * @param _subAccount the id of subaccount to trnasfer
     * @param _newSubAccount the id of receiving account
     */
    function transferAccount(address _subAccount, address _newSubAccount) external {
        if (!_isPrimaryAccountFor(msg.sender, _subAccount)) revert NoAccess();

        if (!marginAccounts[_newSubAccount].isEmpty()) revert AM_AccountIsNotEmpty();
        marginAccounts[_newSubAccount] = marginAccounts[_subAccount];

        delete marginAccounts[_subAccount];
    }

    /**
     * @notice set the margin config for specific productId
     * @dev    expected to be used by Owner or governance
     * @param _productId product id
     * @param _dUpper (sec) max time to expiry to offer a collateral requirement discount
     * @param _dLower (sec) min time to expiry to offer a collateral requirement discount
     * @param _rUpper (BPS) discount ratio if the time to expiry is at the upper bound
     * @param _rLower (BPS) discount ratio if the time to expiry is at the lower bound
     * @param _volMultiplier (BPS) multiplier used to apply to vol from oracle
     */
    function setProductMarginConfig(
        uint32 _productId,
        uint32 _dUpper,
        uint32 _dLower,
        uint32 _rUpper,
        uint32 _rLower,
        uint32 _volMultiplier
    ) external onlyOwner {
        productParams[_productId] = ProductMarginParams({
            dUpper: _dUpper,
            dLower: _dLower,
            sqrtDUpper: uint32(FixedPointMathLib.sqrt(uint256(_dUpper))),
            sqrtDLower: uint32(FixedPointMathLib.sqrt(uint256(_dLower))),
            rUpper: _rUpper,
            rLower: _rLower,
            volMultiplier: _volMultiplier
        });

        emit ProductConfigurationUpdated(_productId, _dUpper, _dLower, _rUpper, _rLower, _volMultiplier);
    }

    /** ========================================================= **
     *                 * -------------------- *                    *
     *                 |  Actions  Functions  |                    *
     *                 * -------------------- *                    *
     *       These functions all update account storages           *
     ** ========================================================= **/

    /**
     * @dev increase the collateral for an account
     */
    function increaseCollateral(
        address _subAccount,
        address _from,
        address _collateral,
        uint8 _collateralId,
        uint80 _amount
    ) external {
        _assertCallerIsGrappa();

        // update the account structure in storage
        marginAccounts[_subAccount].addCollateral(_amount, _collateralId);

        IERC20(_collateral).safeTransferFrom(_from, address(this), _amount);
    }

    /**
     * @dev decrease collateral in account
     */
    function decreaseCollateral(
        address _subAccount,
        address _recipient,
        address _collateral,
        uint8 _collateralId,
        uint80 _amount
    ) external {
        _assertCallerIsGrappa();

        // todo: check if vault has expired short positions

        // update the account structure in storage
        marginAccounts[_subAccount].removeCollateral(_amount, _collateralId);

        IERC20(_collateral).safeTransfer(_recipient, _amount);
    }

    /**
     * @dev increase short position (debt) in account
     */
    function increaseDebt(
        address _subAccount,
        uint256 _optionId,
        uint64 _amount
    ) external {
        _assertCallerIsGrappa();

        // update the account structure in storage
        marginAccounts[_subAccount].mintOption(_optionId, _amount);
    }

    /**
     * @dev decrease the short position (debt) in account
     */
    function decreaseDebt(
        address _subAccount,
        uint256 _optionId,
        uint64 _amount
    ) external {
        _assertCallerIsGrappa();

        // update the account structure in storage
        marginAccounts[_subAccount].burnOption(_optionId, _amount);
    }

    /**
     * @dev change the short position to spread. This will reduce collateral requirement
     */
    function merge(
        address _subAccount,
        uint256 _shortTokenId,
        uint256 _longTokenId,
        uint64 _amount
    ) external {
        _assertCallerIsGrappa();

        // update the account in storage
        marginAccounts[_subAccount].merge(_shortTokenId, _longTokenId, _amount);
    }

    /**
     * @dev Change existing spread position to short. This should increase collateral requirement
     */
    function split(
        address _subAccount,
        uint256 _spreadId,
        uint64 _amount
    ) external {
        _assertCallerIsGrappa();

        // update the account
        marginAccounts[_subAccount].split(_spreadId, _amount);
    }

    /**
     * @notice  settle the margin account at expiry
     */
    function settleAtExpiry(address _subAccount) external {
        // clear the debt in account, and deduct the collateral with reservedPayout
        // this will NOT revert even if account has less collateral than it should have reserved for payout.
        _assertCallerIsGrappa();

        Account memory account = marginAccounts[_subAccount];

        uint80 reservedPayout = _getPayoutFromAccount(account);

        // update the account
        marginAccounts[_subAccount].settleAtExpiry(reservedPayout);
    }

    /** ========================================================= **
                            Internal Functions
     ** ========================================================= **/

    /**
     * @notice return if {_primary} address is the primary account for {_subAccount}
     */
    function _isPrimaryAccountFor(address _primary, address _subAccount) internal pure returns (bool) {
        return (uint160(_primary) | 0xFF) == (uint160(_subAccount) | 0xFF);
    }

    /**
     * @notice revert if called by non-grappa controller
     */
    function _assertCallerIsGrappa() internal view {
        if (msg.sender != address(grappa)) revert NoAccess();
    }

    /**
     * @dev return whether if an account is healthy.
     * @param account account structure in memory
     * @return isHealthy true if account is in good condition, false if it's liquidatable
     */
    function _isAccountHealthy(Account memory account) internal view returns (bool isHealthy) {
        AdvancedMarginDetail memory detail = _getAccountDetail(account);
        uint256 minCollateral = _getMinCollateral(detail);
        isHealthy = account.collateralAmount >= minCollateral;
    }

    /**
     * @notice get minimum collateral needed for a margin account
     * @param detail account memory dtail
     * @return minCollateral minimum collateral required, in collateral asset's decimals
     */
    function _getMinCollateral(AdvancedMarginDetail memory detail) internal view returns (uint256 minCollateral) {
        ProductAssets memory product = _getProductAssets(detail.productId);

        // read spot price of the product, denominated in {UNIT_DECIMALS}.
        // Pass in 0 if margin account has not debt
        uint256 spotPrice;
        uint256 vol;
        if (detail.productId != 0) {
            spotPrice = oracle.getSpotPrice(product.underlying, product.strike);
            vol = volOracle.getImpliedVol(product.underlying);
        }

        // need to pass in collateral/strike price. Pass in 0 if collateral is strike to save gas.
        uint256 collateralStrikePrice = 0;
        if (product.collateral == product.underlying) collateralStrikePrice = spotPrice;
        else if (product.collateral != product.strike) {
            collateralStrikePrice = oracle.getSpotPrice(product.collateral, product.strike);
        }

        uint256 minCollateralInUnit = detail.getMinCollateral(
            product,
            spotPrice,
            collateralStrikePrice,
            vol,
            productParams[detail.productId]
        );

        minCollateral = minCollateralInUnit.convertDecimals(UNIT_DECIMALS, product.collateralDecimals);
    }

    /**
     * @notice  return amount of collateral that should be reserved to payout long positions
     * @dev     this function will revert when called before expiry
     * @param _account account memory
     */
    function _getPayoutFromAccount(Account memory _account) internal view returns (uint80 reservedPayout) {
        (uint256 callPayout, uint256 putPayout) = (0, 0);
        if (_account.shortCallAmount > 0)
            (, , callPayout) = grappa.getPayout(_account.shortCallId, _account.shortCallAmount);
        if (_account.shortPutAmount > 0)
            (, , putPayout) = grappa.getPayout(_account.shortPutId, _account.shortPutAmount);
        return uint80(callPayout + putPayout);
    }

    /**
     * @notice  convert Account struct from storage to in-memory detail struct
     */
    function _getAccountDetail(Account memory account) internal pure returns (AdvancedMarginDetail memory detail) {
        detail = AdvancedMarginDetail({
            putAmount: account.shortPutAmount,
            callAmount: account.shortCallAmount,
            longPutStrike: 0,
            shortPutStrike: 0,
            longCallStrike: 0,
            shortCallStrike: 0,
            expiry: 0,
            collateralAmount: account.collateralAmount,
            productId: 0
        });

        // if it contains a call
        if (account.shortCallId != 0) {
            (, , , uint64 longStrike, uint64 shortStrike) = TokenIdUtil.parseTokenId(account.shortCallId);
            // the short position of the account is the long of the minted optionToken
            detail.shortCallStrike = longStrike;
            detail.longCallStrike = shortStrike;
        }

        // if it contains a put
        if (account.shortPutId != 0) {
            (, , , uint64 longStrike, uint64 shortStrike) = TokenIdUtil.parseTokenId(account.shortPutId);

            // the short position of the account is the long of the minted optionToken
            detail.shortPutStrike = longStrike;
            detail.longPutStrike = shortStrike;
        }

        // parse common field
        // use the OR operator, so as long as one of shortPutId or shortCallId is non-zero, got reflected here
        uint256 commonId = account.shortPutId | account.shortCallId;

        (, uint32 productId, uint64 expiry, , ) = TokenIdUtil.parseTokenId(commonId);
        detail.productId = productId;
        detail.expiry = expiry;
    }

    /**
     * @dev get a struct that stores all relevent token addresses, along with collateral asset decimals
     */
    function _getProductAssets(uint32 _productId) internal view returns (ProductAssets memory info) {
        (, address underlying, address strike, address collateral, uint8 collatDecimals) = grappa
            .getDetailFromProductId(_productId);
        info.underlying = underlying;
        info.strike = strike;
        info.collateral = collateral;
        info.collateralDecimals = collatDecimals;
    }
}