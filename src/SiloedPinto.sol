/**
 * SPDX-License-Identifier: MIT
 **/

pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPintoProtocol, From, To} from "src/interfaces/IPintoProtocol.sol";
import {AbstractSiloedPinto} from "src/AbstractSiloedPinto.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title SiloedPinto
 * @author Natto, DefaultJuice
 * @dev ERC4626 compliant interest bearing wrapper around Pinto Silo deposits.
 */
contract SiloedPinto is AbstractSiloedPinto {
    using Math for uint256;
    using SafeERC20 for IERC20;

    // Block initialization on all logic contracts.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @dev Calls the initialize function from the parent contract.
    function initialize(
        uint256 _maxTriggerPrice,
        uint256 _slippageRatio,
        uint256 _floodTranchRatio,
        uint256 _vestingPeriod,
        uint256 _minSize,
        uint256 _targetMinSize
    ) public override initializer {
        super.initialize(
            _maxTriggerPrice,
            _slippageRatio,
            _floodTranchRatio,
            _vestingPeriod,
            _minSize,
            _targetMinSize
        );
    }

    /* --------------------- ERC4626 FUNCTIONS --------------------- */

    ////////////////// DEPOSIT/MINT //////////////////

    /**
     * @dev See {IERC4626-deposit}.
     * Deposits `assets` into the conract in exchange for shares (sPinto) and credits the receiver.
     * A maximum deposit is not enforced but a check is done for erc4626 compliance.
     * When calculating the amount of shares minted, we round in favor of the protocol.
     * @param assets The amount of assets (Pinto) to deposit.
     * @param receiver The address to credit the shares (sPinto) to.
     * @return shares The amount of shares (sPinto) minted to the receiver.
     */
    function deposit(
        uint256 assets,
        address receiver
    ) public override upOrRight nonReentrant returns (uint256 shares) {
        _checkMaxDeposit(receiver, assets);
        shares = previewDeposit(assets);
        _deposit(assets, shares, receiver, From.EXTERNAL, To.EXTERNAL);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /**
     * @dev Deposit function variant that allows specifying `from` and `to` farm modes.
     * Used for depositing in the contract using internal Pinto protocol balances.
     * Deposits assets into the contract by pulling Pinto from the `from` mode.
     * Mints shares (sPinto) to the `to` mode of the receiver.
     * A maximum deposit is not enforced but a check is done for erc4626 compliance.
     * @param assets The amount of assets (Pinto) to deposit.
     * @param receiver The address to credit the shares (sPinto) to.
     * @param fromMode The mode to pull the assets from. See {IPintoProtocol.From}.
     * @param toMode The mode to mint the shares to. See {IPintoProtocol.To}.
     * @return shares The amount of shares (sPinto) minted to the receiver.
     */
    function depositAdvanced(
        uint256 assets,
        address receiver,
        From fromMode,
        To toMode
    ) public upOrRight nonReentrant returns (uint256 shares) {
        _checkMaxDeposit(receiver, assets);
        shares = previewDeposit(assets);
        _deposit(assets, shares, receiver, fromMode, toMode);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /**
     * @dev Deposit function variant that allows minting of sPinto using Pinto protocol Silo deposits.
     * Mints shares by transferring silo deposits from the sender to the contract
     * and adding them to the deposit queue.
     * note: Since stalk is socialized between all depositors, users calling this function
     * can and should expect to lose the grown stalk of their inbound deposits when redeeming.
     * note: Requires a deposit approval on the protocol from the sender via `approveDeposit`
     * note: Users depositing silo deposits with low stems may cause this function to run out of gas.
     * note: Instead of using the notZero modifier, we check for zero assets and shares
     * to revert early without interacting with the protocol.
     * @param stems The stems of the Silo deposits to mint shares from.
     * @param amounts The underlying Pinto amounts of the Silo deposits to mint shares from.
     * @param receiver The address to credit the shares (sPinto) to.
     * @param toMode The mode to mint the shares to. See {IPintoProtocol.To}.
     * @return shares The amount of shares (sPinto) minted to the receiver.
     */
    function depositFromSilo(
        int96[] memory stems,
        uint256[] memory amounts,
        address receiver,
        To toMode
    ) public upOrRight nonReentrant returns (uint256 shares) {
        if (stems.length != amounts.length) revert StemsAmountMismatch();
        uint256 assets;
        for (uint256 i = 0; i < stems.length; i++) {
            assets += amounts[i];
        }
        if (assets == 0) revert ZeroAssets();
        _checkMaxDeposit(receiver, assets);
        shares = previewDeposit(assets);
        if (shares == 0) revert ZeroShares();
        PINTO_PROTOCOL.transferDeposits(msg.sender, address(this), PINTO_ADDRESS, stems, amounts);
        _accountForInboundDeposits(assets, shares, stems, amounts, receiver, toMode);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /**
     * @dev See {IERC4626-mint}.
     * Mints exactly `shares` (sPinto) to `receiver` by depositing an amount of underlying tokens.
     * A maximum mint is not enforced but a check is done for erc4626 compliance.
     * When calculating the amount of assets needed, we round in favor of the protocol.
     * @param shares The amount of shares (sPinto) to mint.
     * @param receiver The address to credit the shares (sPinto) to.
     * @return assets The amount of assets (Pinto) deposited to mint the specified shares.
     */
    function mint(
        uint256 shares,
        address receiver
    ) public override upOrRight nonReentrant returns (uint256 assets) {
        _checkMaxMint(receiver, shares);
        assets = previewMint(shares);
        _deposit(assets, shares, receiver, From.EXTERNAL, To.EXTERNAL);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /**
     * @dev Mint function variant that allows specifying `from` and `to` farm modes.
     * Used for minting in the contract using internal Pinto protocol balances.
     * Mints exactly `shares` (sPinto) to `receiver` by depositing an amount of underlying tokens.
     * A maximum mint is not enforced but a check is done for erc4626 design compliance.
     * @param shares The amount of shares (sPinto) to mint.
     * @param receiver The address to credit the shares (sPinto) to.
     * @param fromMode The mode to deposit the assets from. See {IPintoProtocol.From}.
     * @param toMode The mode to mint the shares to. See {IPintoProtocol.To}.
     * @return assets The amount of assets (Pinto) deposited to mint the specified shares.
     */
    function mintAdvanced(
        uint256 shares,
        address receiver,
        From fromMode,
        To toMode
    ) public upOrRight nonReentrant returns (uint256 assets) {
        _checkMaxMint(receiver, shares);
        assets = previewMint(shares);
        _deposit(assets, shares, receiver, fromMode, toMode);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    ////////////////// WITHDRAW/REDEEM //////////////////

    /**
     * @dev See {IERC4626-withdraw}.
     * Burns shares (sPinto) from owner and sends exactly assets of underlying tokens to receiver.
     * Enforces that the owner has enough shares to withdraw the requested assets.
     * note: Users withdrawing large amounts of assets may cause this function to run out of gas due to
     * the ordered deposit list. In this case, users should split withdrawals into multiple transactions.
     * @param assets The amount of assets (Pinto) to withdraw.
     * @param receiver The address to send the withdrawn assets to.
     * @param owner The address to burn the shares (sPinto) from.
     */
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override upOrRight nonReentrant returns (uint256 shares) {
        _checkMaxWithdraw(owner, assets, From.EXTERNAL);
        shares = previewWithdraw(assets);
        _redeem(assets, shares, receiver, owner, From.EXTERNAL, To.EXTERNAL);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /**
     * @dev Withdraw function variant that allows specifying `from` and `to` farm modes.
     * Used for withdrawing in the contract using internal Pinto protocol balances.
     * Burns shares from owner and sends exactly `assets` of underlying tokens to receiver.
     * @param assets The amount of assets (Pinto) to withdraw.
     * @param receiver The address to send the withdrawn assets to.
     * @param owner The address to burn the shares (sPinto) from.
     * @param fromMode The mode to burn the shares from. See {IPintoProtocol.From}.
     * @param toMode The mode to credit the withdrawn assets to. See {IPintoProtocol.To}.
     * @return shares The amount of shares (sPinto) burned from the owner.
     */
    function withdrawAdvanced(
        uint256 assets,
        address receiver,
        address owner,
        From fromMode,
        To toMode
    ) public upOrRight nonReentrant returns (uint256 shares) {
        _checkMaxWithdraw(owner, assets, fromMode);
        shares = previewWithdraw(assets);
        _redeem(assets, shares, receiver, owner, fromMode, toMode);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /**
     * @dev Withdraw function variant that allows withdrawing of sPinto to Pinto protocol Silo deposits.
     * Burns shares (sPinto) from owner and transfers the withdrawn Silo deposits to the receiver.
     * The received Silo deposits have exactly `assets` PDV value.
     * note: Since stalk is socialized between all depositors, users calling this function
     * can and should expect to receive the worst possible deposits, containing
     * zero grown stalk and potentially be germinating.
     * @param assets The amount of assets (Pinto) to withdraw.
     * @param receiver The address to send the withdrawn Silo deposits to.
     * @param owner The address to burn the shares (sPinto) from.
     * @param fromMode The mode to burn the shares from. See {IPintoProtocol.From}.
     * @return stems The stems of the Silo deposits withdrawn.
     * @return amounts The underlying Pinto amounts of the Silo deposits withdrawn.
     */
    function withdrawToSilo(
        uint256 assets,
        address receiver,
        address owner,
        From fromMode
    ) public upOrRight nonReentrant returns (int96[] memory stems, uint256[] memory amounts) {
        _checkMaxWithdraw(owner, assets, fromMode);
        uint256 shares = previewWithdraw(assets);
        (stems, amounts) = _accountForOutboundDeposits(assets, shares, owner, fromMode);
        PINTO_PROTOCOL.transferDeposits(address(this), receiver, PINTO_ADDRESS, stems, amounts);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /**
     * @dev See {IERC4626-redeem}.
     * Burns exactly `shares` from owner and sends `assets` of underlying tokens to receiver.
     * Enforces that the owner can redeem all the requested shares in a single call.
     * @param shares The amount of shares (sPinto) to burn.
     * @param receiver The address to send the withdrawn assets (Pinto) to.
     * @param owner The address to burn the shares (sPinto) from.
     */
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public override upOrRight nonReentrant returns (uint256 assets) {
        _checkMaxRedeem(owner, shares, From.EXTERNAL);
        assets = previewRedeem(shares);
        _redeem(assets, shares, receiver, owner, From.EXTERNAL, To.EXTERNAL);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /**
     * @dev Redeem function variant that allows specifying `from` and `to` farm modes.
     * Used for redeeming in the contract using internal Pinto protocol balances.
     * Redeems for assets (Pinto) by burning shares (sPinto) from the `from` mode of the owner.
     * Credits the withdrawn assets to the `to` mode of the receiver.
     * Enforces that the owner can redeem all the requested shares in a single call.
     * @param shares The amount of shares (sPinto) to burn.
     * @param receiver The address to send the withdrawn assets (Pinto) to.
     * @param owner The address to burn the shares (sPinto) from.
     * @param fromMode The mode to burn the shares from. See {IPintoProtocol.From}.
     * @param toMode The mode to credit the withdrawn assets to. See {IPintoProtocol.To}.
     * @return assets The amount of assets (Pinto) withdrawn from redeeming the specified shares.
     */
    function redeemAdvanced(
        uint256 shares,
        address receiver,
        address owner,
        From fromMode,
        To toMode
    ) public upOrRight nonReentrant returns (uint256 assets) {
        _checkMaxRedeem(owner, shares, fromMode);
        assets = previewRedeem(shares);
        _redeem(assets, shares, receiver, owner, fromMode, toMode);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /**
     * @dev Redeem function variant that allows redeeming of sPinto to Pinto protocol Silo deposits.
     * Burns shares (sPinto) from the owner and transfers the withdrawn Silo deposits to the receiver.
     * note: Since stalk is socialized between all depositors, users calling this function
     * can and should expect to receive the worst possible deposits, containing
     * zero grown stalk and potentially be germinating.
     * @param shares The amount of shares (sPinto) to burn.
     * @param receiver The address to send the withdrawn Silo deposits to.
     * @param owner The address to burn the shares (sPinto) from.
     * @param fromMode The mode to burn the shares from. See {IPintoProtocol.From}.
     * @return stems The stems of the Silo deposits redeemed.
     * @return amounts The underlying Pinto amounts of the Silo deposits redeemed.
     */
    function redeemToSilo(
        uint256 shares,
        address receiver,
        address owner,
        From fromMode
    ) public upOrRight nonReentrant returns (int96[] memory stems, uint256[] memory amounts) {
        _checkMaxRedeem(owner, shares, fromMode);
        uint256 assets = previewRedeem(shares);
        (stems, amounts) = _accountForOutboundDeposits(assets, shares, owner, fromMode);
        PINTO_PROTOCOL.transferDeposits(address(this), receiver, PINTO_ADDRESS, stems, amounts);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /* -------------------- GETTERS -------------------- */

    ////////////////// ASSETS/SHARES //////////////////

    /** @dev See {IERC4626-totalAssets}. */
    function totalAssets() public view override returns (uint256 totalManagedAssets) {
        return underlyingPdv - _unvestedAssets();
    }

    /**
     * @notice Calculate the amount of Pinto that are unvested.
     * @return assets amount of Pinto that are unvested. Return is deducted from totalAssets.
     */
    function unvestedAssets() public view returns (uint256 assets) {
        return _unvestedAssets();
    }

    ////////////////// LIMITS //////////////////

    /**
     * @dev maxWithdraw variant that allows specifying `from` mode.
     * If the `from` mode is external, the default maxWithdraw is used, using balanceOf.
     * If the `from` mode is internal, the maxWithdraw is calculated from the internal sPinto balances.
     * Both modes convert the shares to assets and return the maximum withdrawable amount.
     */
    function getMaxWithdraw(address owner, From fromMode) public view returns (uint256) {
        if (fromMode == From.EXTERNAL) {
            return maxWithdraw(owner);
        } else if (fromMode == From.INTERNAL) {
            return _maxWithdrawFromInternal(owner);
        } else {
            revert InvalidMode();
        }
    }

    /**
     * @dev maxRedeem variant that allows specifying `from` mode.
     * If the `from` mode is external, the default maxRedeem is used, returning the balance of the owner.
     * If the `from` mode is internal, the maxRedeem is the internal sPinto balance of the owner.
     */
    function getMaxRedeem(address owner, From fromMode) public view returns (uint256) {
        if (fromMode == From.EXTERNAL) {
            return maxRedeem(owner);
        } else if (fromMode == From.INTERNAL) {
            return _maxRedeemFromInternal(owner);
        } else {
            revert InvalidMode();
        }
    }

    ////////////////// PREVIEW FUNCTIONS //////////////////

    /** @dev See {IERC4626-previewDeposit}. */
    function previewDeposit(uint256 assets) public view override returns (uint256 shares) {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    /** @dev See {IERC4626-previewMint}. */
    function previewMint(uint256 shares) public view override returns (uint256 assets) {
        return _convertToAssets(shares, Math.Rounding.Ceil);
    }

    /** @dev See {IERC4626-previewWithdraw}. */
    function previewWithdraw(uint256 assets) public view override returns (uint256 shares) {
        return _convertToShares(assets, Math.Rounding.Ceil);
    }

    /** @dev See {IERC4626-previewRedeem}. */
    function previewRedeem(uint256 shares) public view override returns (uint256 assets) {
        return _convertToAssets(shares, Math.Rounding.Floor);
    }

    /* -------------------- SETTERS -------------------- */

    /** @dev Sets the USD per Pinto max before triggering a flood swap using 6 decimal precision. */
    function setMaxTriggerPrice(
        uint256 _maxTriggerPrice
    ) external onlyOwner {
        maxTriggerPrice = _maxTriggerPrice;
    }

    /** @dev Sets the max slippage between current and instant (EMA) price using 18 decimal precision. */
    function setSlippageRatio(uint256 _slippageRatio) external onlyOwner {
        slippageRatio = _slippageRatio;
    }

    /** @dev Sets the ratio of flood asset balance to distribute on each swap using 18 decimal precision. */
    function setFloodTranchRatio(
        uint256 _floodTranchRatio
    ) external onlyOwner {
        floodTranchRatio = _floodTranchRatio;
    }

    /** @dev Sets the vesting period for earned pinto rewards. */
    function setVestingPeriod(uint256 _vestingPeriod) external onlyOwner {
        vestingPeriod = _vestingPeriod;
    }

    /** @dev Sets the minimum Pinto deposit size. */
    function setMinSize(uint256 _minSize) external onlyOwner {
        minSize = _minSize;
    }

    /** @dev Sets the minimum Pinto deposit size. */
    function setTargetMinSize(uint256 _targetMinSize) external onlyOwner {
        targetMinSize = _targetMinSize;
    }

    /* -------------------- MISC FUNCTIONS -------------------- */

    /**
     * @notice Call gm, mow and plant on the Pinto Protocol, handle vesting and flood.
     * @dev Anyone can call this function on behalf of the contract to claim silo yield.
     */
    function claim() external upOrRight nonReentrant {
        return;
    }

    /**
     * @notice Allows the owner to rescue tokens. Serves 2 purposes:
     * - Recovers tokens accidentally sent to the contract, including Pinto and sPinto.
     * - Recovers flood assets in case of emergency/bug in flood logic
     *   so that they are manually handled by the owner and redeposited.
     * note: All assets are tracked as underlyingPdv and deposited so the
     * contract should never hold any tokens that are not in Silo deposits or flood assets.
     * @param token The token to be rescued.
     * @param amount The amount of tokens to be rescued.
     * @param to Where to send rescued tokens
     */
    function rescueTokens(
        address token,
        uint256 amount,
        address to
    ) external onlyOwner upOrRight nonReentrant {
        IERC20(token).safeTransfer(to, amount);
    }

    /**
     * @notice Returns a deposit from combined deposits queue + germinating deposits queue.
     */
    function getDeposit(uint256 index) external view returns (SiloDeposit memory) {
        if (index < deposits.length) {
            return deposits[index];
        }
        return germinatingDeposits[index - deposits.length];
    }

    /**
     * @notice Returns the length of the deposits queue + germinating deposits queue.
     */
    function getDepositsLength() external view returns (uint256) {
        return deposits.length + germinatingDeposits.length;
    }

    /**
     * @notice Returns the length of the germinating deposits queue.
     */
    function getGerminatingDepositsLength() external view returns (uint256) {
        return germinatingDeposits.length;
    }

    /**
     * @notice Returns the version of the contract, used to keep track of upgrades.
     */
    function version() external pure virtual returns (string memory) {
        return "1.0.1";
    }
}
