/**
 * SPDX-License-Identifier: MIT
 **/

pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {IPintoProtocol, From, To, ConvertKind, ClaimPlentyData} from "src/interfaces/IPintoProtocol.sol";
import {IWell} from "src/interfaces/IWell.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LibPrice} from "src/LibPrice.sol";

contract AbstractSiloedPinto is ERC4626Upgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using Math for uint256;

    struct SiloDeposit {
        int96 stem;
        uint160 amount;
    }

    /* ------------- CONSTANTS ------------- */

    // Protocol.
    address internal constant PINTO_PROTOCOL_ADDRESS = 0xD1A0D188E861ed9d15773a2F3574a2e94134bA8f;
    address internal constant PINTO_ADDRESS = 0xb170000aeeFa790fa61D6e837d1035906839a3c8;
    IPintoProtocol internal constant PINTO_PROTOCOL = IPintoProtocol(PINTO_PROTOCOL_ADDRESS);
    IERC20 internal constant PINTO = IERC20(PINTO_ADDRESS);

    // Owner.
    address internal constant PCM = 0x2cf82605402912C6a79078a9BBfcCf061CbfD507;

    // Token.
    uint256 constant DECIMALS = 1e18;

    // Events.
    event Update(uint256 totalAssets, uint256 totalShares);

    /* ------------- ERRORS ------------- */

    /// @dev Error emitted when the farm mode used is invalid or not supported.
    error InvalidMode();

    /// @dev Error emitted when the owner attempts to rescue Pinto from the contract.
    error InvalidToken();

    /// @dev Error emitted when the PDV per token decreases during a transaction.
    error PdvDecrease();

    /// @dev Error emitted when the minimum PDV requirement is not met.
    error MinPdvViolation();

    /// @dev Error emitted when assets are zero.
    error ZeroAssets();

    /// @dev Error emitted when shares are zero.
    error ZeroShares();

    /// @dev Error emitted when amount requested for withdrawal to silo is not sufficient.
    error InsufficientDepositAmount();

    /// @dev Error emitted when different lengths of stems and amounts arrays are provided.
    error StemsAmountMismatch();

    /// @dev Error emitted when a germinating deposit is not a standard germinating stem.
    error InvalidGerminatingStem();

    /// @dev Error emitted when a deposit is not added to the list.
    error DepositNotInserted();

    /* ------------- STATE VARIABLES ------------- */

    /// @dev Ordered array of Pinto deposits, from lowest to highest Stem.
    SiloDeposit[] public deposits;
    SiloDeposit[] public germinatingDeposits;

    /// @dev The total pdv of the silo deposits in the contract, updated on mint/claim/redeem.
    uint256 public underlyingPdv;

    /// @dev The amount of Pinto that are unvested from claims.
    uint256 public vestingPinto;

    /// @dev The timestamp at which a claim with earned Pinto was executed.
    uint256 public lastEarnedTimestamp;

    /// @dev Local tracker to avoid unnecessary checking for local flood assets.
    bool public floodAssetsPresent;

    // Flood Configuration.
    /// @dev USD per Pinto max before triggering a flood swap. 6 decimal precision.
    uint256 public maxTriggerPrice;
    /// @dev Max slippage between current and instant price. 18 decimal precision.
    uint256 public slippageRatio;
    /// @dev The ratio of flood asset balance to distribute on each swap. 18 decimal precision.
    uint256 public floodTranchRatio;

    /// @dev The vesting period for earned pinto rewards is 2 hours.
    uint256 public vestingPeriod;

    /// @dev Minimum Pinto needed for mint or plant to prevent griefing.
    uint256 public minSize;

    /// @dev The target minimum size for a deposit.
    uint256 public targetMinSize;

    /// @dev The amount of each asset to swap per flood swap.
    mapping(address => uint256) public trancheSizes;

    /// @dev Slot gap reserved for future upgrades.
    uint256[50] __gap;

    /* ------------- MODIFIERS ------------- */

    /**
     * @notice Any change to the system should first claim. The full call will either
     * increase the PDV per token or leave it unchanged.
     * @dev Should be added to every externally accessible write function (except claim).
     */
    modifier upOrRight() {
        _claim();
        uint256 prePdvPerToken = previewRedeem(DECIMALS);
        _;
        uint256 postPdvPerToken = previewRedeem(DECIMALS);
        if (postPdvPerToken < prePdvPerToken) {
            revert PdvDecrease();
        }
        emit Update(totalAssets(), totalSupply());
    }

    /**
     * @notice ensure input amount is not zero
     * Protects against burning small amount of shares for no assets
     * due to rounding errors when redeeming.
     */
    modifier notZero(uint256 assets, uint256 shares) {
        if (assets == 0) revert ZeroAssets();
        if (shares == 0) revert ZeroShares();
        _;
    }

    /* ------------- INITIALIZER ------------- */

    function initialize(
        uint256 _maxTriggerPrice,
        uint256 _slippageRatio,
        uint256 _floodTranchRatio,
        uint256 _vestingPeriod,
        uint256 _minSize,
        uint256 _targetMinSize
    ) public virtual onlyInitializing {
        // init config variables
        maxTriggerPrice = _maxTriggerPrice;
        slippageRatio = _slippageRatio;
        floodTranchRatio = _floodTranchRatio;
        vestingPeriod = _vestingPeriod;
        minSize = _minSize;
        targetMinSize = _targetMinSize;
        // init name and symbol
        __ERC20_init("Siloed Pinto", "sPINTO");
        // init asset() to be pinto and store the decimals
        __ERC4626_init(PINTO);
        // init owner to be the pcm
        __Ownable_init(PCM);
        __ReentrancyGuard_init();
        // Approve the Pinto Diamond to spend passthrough tokens.
        PINTO.approve(PINTO_PROTOCOL_ADDRESS, type(uint256).max);
        // Pre-approve the diamond to spend sPinto for transfers.
        _approve(address(this), PINTO_PROTOCOL_ADDRESS, type(uint256).max);
    }

    /**
     * @notice Pull Pinto from a user's external or internal balance and deposit it.
     * @param assets The amount of Pinto to deposit.
     * @param receiver The address to receive the shares.
     * @param fromMode The source of the Pinto.
     */
    function _deposit(
        uint256 assets,
        uint256 shares,
        address receiver,
        From fromMode,
        To toMode
    ) internal notZero(assets, shares) {
        if (fromMode == From.INTERNAL) {
            PINTO_PROTOCOL.transferInternalTokenFrom(
                PINTO,
                msg.sender,
                address(this),
                assets,
                To.INTERNAL
            );
        } else if (fromMode == From.EXTERNAL) {
            PINTO.transferFrom(msg.sender, address(this), assets);
            PINTO_PROTOCOL.transferToken(PINTO, address(this), assets, From.EXTERNAL, To.INTERNAL);
        } else {
            revert InvalidMode();
        }

        int96[] memory stems = new int96[](1);
        uint256[] memory amounts = new uint256[](1);
        (amounts[0], , stems[0]) = PINTO_PROTOCOL.deposit(PINTO_ADDRESS, assets, From.INTERNAL);

        return _accountForInboundDeposits(assets, shares, stems, amounts, receiver, toMode);
    }

    /**
     * @notice Pull pinto from the deposit list and transfer it to the user.
     * @param assets The amount of Pinto to withdraw.
     * @param shares The amount of sPinto to burn.
     * @param receiver The address to receive the Pinto.
     * @param owner The address of the owner of the sPinto.
     * @param fromMode The mode where to transfer the sPinto from.
     * @param toMode The mode where to transfer the Pinto to.
     */
    function _redeem(
        uint256 assets,
        uint256 shares,
        address receiver,
        address owner,
        From fromMode,
        To toMode
    ) internal notZero(assets, shares) {
        int96[] memory stems;
        uint256[] memory amounts;
        (stems, amounts) = _accountForOutboundDeposits(assets, shares, owner, fromMode);
        PINTO_PROTOCOL.withdrawDeposits(PINTO_ADDRESS, stems, amounts, To.INTERNAL);
        PINTO_PROTOCOL.transferToken(PINTO, receiver, assets, From.INTERNAL, toMode);
    }

    /**
     * @notice Variant of the burn function that allows specifying farm modes.
     * Burns sPinto from the sender's internal or external balance and spends the allowance if needed.
     * @param shares The amount of sPinto to burn.
     * @param fromMode The mode where to burn the sPinto from.
     */
    function _burnAdvanced(address account, uint256 shares, From fromMode) internal {
        if (account != _msgSender()) {
            _spendAllowance(account, _msgSender(), shares);
        }
        if (fromMode == From.INTERNAL) {
            PINTO_PROTOCOL.transferInternalTokenFrom(
                this,
                account,
                address(this),
                shares,
                To.EXTERNAL
            );
            _burn(address(this), shares);
        } else if (fromMode == From.EXTERNAL) {
            _burn(account, shares);
        } else {
            revert InvalidMode();
        }
    }

    /**
     * @notice Add a deposit into the deposit list.
     * @dev Ensures the deposits are ordered by stem.
     * @param stem The stem of the deposit to add to the deposit list.
     * @param amount The amount of the deposit to add to the deposit list.
     * - If the array is empty, push the deposit.
     * - If this deposit stem already exists, increment the amount.
     * - If the array has elements and the new stem is greater than the last element:
     *     - If last element amount is less than target size, merge the deposits.
     *     - Else push the deposit.
     * - If the stem is less than the last element, merge it into an existing deposit.
     */
    function _addDeposit(int96 stem, uint256 amount) internal {
        uint160 amount160 = uint160(amount);
        int96 nonGerminatingStem = _getHighestNonGerminatingPintoStem();
        // if incoming stem is germinating, put it in the germinating deposit list.
        if (stem > nonGerminatingStem) {
            _insertGerminatingDeposit(stem, amount160);
            return;
        }

        // If normal deposit list is empty, just push the deposit.
        if (deposits.length == 0) {
            deposits.push(SiloDeposit({stem: stem, amount: amount160}));
            return;
        }

        // Special case appending to end of array.
        // If the incoming deposit is non germinating and the previous deposit amount
        // exceeds the target size, just push the deposit to the next index.
        if (stem > deposits[deposits.length - 1].stem) {
            if (deposits[deposits.length - 1].amount > targetMinSize) {
                deposits.push(SiloDeposit({stem: stem, amount: amount160}));
                return;
            }
        }

        // Iterate and inject incoming non germinating deposit into an existing deposit.
        uint256 destinationIndex = type(uint256).max;
        uint256 i = deposits.length;
        while (i > 0) {
            i--;
            // The incoming deposit stem is already in the list, just increase the amount.
            if (stem == deposits[i].stem) {
                deposits[i].amount += amount160;
                return;
            }
            // Find the next adjascent deposit to merge with.
            if (stem > deposits[i].stem && i < deposits.length - 1) {
                // Insert the deposit at the next index and lambda2lambda convert.
                destinationIndex = i + 1;
            } else if (i == 0) {
                // New stem is smaller than all existing stems,
                // lambda2lambda convert incoming stem with the smallest existing stem.
                destinationIndex = 0;
            }
            // We found a target deposit index to lambda2lambda convert with incoming deposit.
            // Since the incoming deposit stem and the found deposit stem are adjacent,
            // and we haven't modified the deposit list length, we can safely merge them,
            // ensuring that the merged stem position is correct.
            if (destinationIndex < type(uint256).max) {
                // lambda2lambda convert the incoming deposit with the target deposit.
                (int96 mergedStem, uint256 mergedAmount) = _lambdaLambdaConvert(
                    stem,
                    amount,
                    deposits[destinationIndex].stem,
                    deposits[destinationIndex].amount
                );
                // Replace the target deposit with the merged deposit.
                deposits[destinationIndex] = SiloDeposit({
                    stem: mergedStem,
                    amount: uint160(mergedAmount)
                });
                return;
            }
        }
        revert DepositNotInserted();
    }

    /**
     * @notice Merge two deposits into a single deposit using Pinto L2L conversion.
     * @param stem0 The stem of the first deposit.
     * @param amount0 The amount of the first deposit.
     * @param stem1 The stem of the second deposit.
     * @param amount1 The amount of the second deposit.
     * @return mergedStem The stem of the merged deposit.
     * @return mergedAmount The amount of the merged deposit.
     */
    function _lambdaLambdaConvert(
        int96 stem0,
        uint256 amount0,
        int96 stem1,
        uint256 amount1
    ) internal returns (int96 mergedStem, uint256 mergedAmount) {
        bytes memory convertData = abi.encode(
            ConvertKind.LAMBDA_LAMBDA,
            amount0 + amount1,
            PINTO_ADDRESS
        );
        int96[] memory stems = new int96[](2);
        uint256[] memory amounts = new uint256[](2);
        stems[0] = stem0;
        amounts[0] = amount0;
        stems[1] = stem1;
        amounts[1] = amount1;
        (mergedStem, , mergedAmount, , ) = PINTO_PROTOCOL.convert(convertData, stems, amounts);
    }

    /**
     * @notice Insert a germinating deposit into the germinating deposit list.
     * @dev List is sorted by stem.
     * @dev Germinating deposit length will not exceed 2.
     * @param stem The stem of the germinating deposit to insert.
     * @param amount The amount of the germinating deposit to insert.
     */
    function _insertGerminatingDeposit(int96 stem, uint160 amount) internal {
        // Only accept germinating stems from direct Pinto deposits in current or previous season.
        if (
            stem != PINTO_PROTOCOL.getGerminatingStem(PINTO_ADDRESS) &&
            stem != PINTO_PROTOCOL.stemTipForToken(PINTO_ADDRESS)
        ) {
            revert InvalidGerminatingStem();
        }

        if (
            germinatingDeposits.length == 0 ||
            stem > germinatingDeposits[germinatingDeposits.length - 1].stem
        ) {
            germinatingDeposits.push(SiloDeposit({stem: stem, amount: amount}));
            return;
        }

        // Check if deposit already exists in the germinating deposits list and increment amount.
        uint256 i = germinatingDeposits.length;
        while (i > 0) {
            i--;
            if (germinatingDeposits[i].stem == stem) {
                germinatingDeposits[i].amount += amount;
                return;
            }
        }

        // If deposit does not exist, insert it into the list and shift existing deposits.
        i = germinatingDeposits.length;
        germinatingDeposits.push(SiloDeposit({stem: 0, amount: 0}));
        while (i > 0) {
            i--;
            germinatingDeposits[i + 1] = germinatingDeposits[i];
            if (i == 0 || stem > germinatingDeposits[i - 1].stem) {
                germinatingDeposits[i] = SiloDeposit({stem: stem, amount: amount});
                return;
            }
        }
    }

    /**
     * @notice Check the germinating deposits and merge them into existing deposits if possible.
     * @dev There will be no more than 2 germinating deposits at a time.
     */
    function _processGerminatingDeposits() internal {
        int96 nonGerminatingStem = _getHighestNonGerminatingPintoStem();
        uint256 popCount;
        for (uint256 i; i < germinatingDeposits.length; i++) {
            if (germinatingDeposits[i].stem <= nonGerminatingStem) {
                _addDeposit(germinatingDeposits[i].stem, germinatingDeposits[i].amount);
                popCount++;
            }
        }

        if (popCount == 0) return;
        else if (popCount == germinatingDeposits.length) {
            delete germinatingDeposits;
        } else {
            for (uint256 i = popCount; i < germinatingDeposits.length; i++) {
                germinatingDeposits[i - popCount] = germinatingDeposits[i];
            }
            for (uint256 i = 0; i < popCount; i++) {
                germinatingDeposits.pop();
            }
        }
    }

    /**
     * @notice Get the deposits that would be needed to withdraw a given amount of Pinto.
     * @param assets The amount of Pinto to withdraw.
     * @return depositCount The number of deposits needed to withdraw the given amount of Pinto.
     */
    function _calcNumWithdrawDeposits(uint256 assets) internal view returns (uint256 depositCount) {
        uint256 depositAmountsSum;
        uint256 i = deposits.length;
        while (i > 0) {
            i--;
            depositAmountsSum += uint256(deposits[i].amount);
            if (depositAmountsSum >= assets) {
                depositCount = deposits.length - i;
                break;
            }
        }
        if (depositCount == 0) revert InsufficientDepositAmount();
    }

    /**
     * @notice Update state variables for new deposits and mint sPinto. Does not deposit.
     * @param assets The amount of Pinto corresponding to new deposits. Sum of amounts.
     * @param shares The amount of sPinto minted as a result of the deposits.
     * @param stems The stems of the new deposits.
     * @param amounts The amounts of the new deposits.
     * @param receiver The address to receive the sPinto.
     * @param toMode The mode where to transfer the sPinto.
     */
    function _accountForInboundDeposits(
        uint256 assets,
        uint256 shares,
        int96[] memory stems,
        uint256[] memory amounts,
        address receiver,
        To toMode
    ) internal notZero(assets, shares) {
        if (assets < minSize) revert MinPdvViolation();
        for (uint256 i = 0; i < stems.length; i++) {
            _addDeposit(stems[i], amounts[i]);
        }
        underlyingPdv += assets;
        if (toMode == To.EXTERNAL) {
            _mint(receiver, shares);
        } else if (toMode == To.INTERNAL) {
            _mint(address(this), shares);
            PINTO_PROTOCOL.transferToken(
                IERC20(address(this)),
                receiver,
                shares,
                From.EXTERNAL,
                To.INTERNAL
            );
        } else {
            revert InvalidMode();
        }
    }

    /**
     * @notice Update state variables for exiting deposits and burn sPinto. Does not withdraw.
     * @param assets The amount of Pinto corresponding to exiting deposits.
     * @param shares The amount of sPinto corresponding to exiting deposits.
     * @param owner The owner of the sPinto.
     * @param fromMode The mode where to burn the sPinto from.
     * @return stems The stems of the deposits.
     * @return amounts The amounts of the deposits.
     */
    function _accountForOutboundDeposits(
        uint256 assets,
        uint256 shares,
        address owner,
        From fromMode
    ) internal notZero(assets, shares) returns (int96[] memory stems, uint256[] memory amounts) {
        // Temporarily add germinating deposits to the deposits list (max 2).
        // Cheaper than moving all deposits to a concatenated memory array.
        uint256 i;
        for (i = 0; i < germinatingDeposits.length; i++) {
            deposits.push(germinatingDeposits[i]);
        }
        delete germinatingDeposits;

        uint256 depositCount = _calcNumWithdrawDeposits(assets);
        stems = new int96[](depositCount);
        amounts = new uint256[](depositCount);

        uint256 depositsInitialLength = deposits.length;
        uint256 totalAmount;
        i = depositCount;
        while (i > 0) {
            i--;
            uint256 depositIndex = depositsInitialLength - depositCount + i;
            stems[i] = deposits[depositIndex].stem;
            if (i > 0) {
                amounts[i] = uint256(deposits[depositIndex].amount);
                deposits.pop();
                totalAmount += amounts[i];
                continue;
            }

            // Final deposit.
            amounts[i] = assets - totalAmount;
            // If withdrawing the entire last deposit.
            if (amounts[i] == uint256(deposits[depositIndex].amount)) {
                deposits.pop();
            }
            // Else partial withdraw.
            else {
                deposits[depositIndex].amount -= uint160(amounts[i]);
            }
        }

        underlyingPdv -= assets;
        _burnAdvanced(owner, shares, fromMode);

        // Move any remaining germinating deposits back to germinating array.
        int96 nonGerminatingStem = _getHighestNonGerminatingPintoStem();
        i = deposits.length;
        while (i > 0) {
            i--;
            if (deposits[i].stem > nonGerminatingStem) {
                _insertGerminatingDeposit(deposits[i].stem, deposits[i].amount);
                deposits.pop();
            } else {
                break;
            }
        }
    }

    /**
     * @notice Accrues earned pinto yield and stalk growth, swaps flood rewards.
     * Adds the earned pinto to the deposit list and linearly vests it.
     */
    function _claim() internal {
        _processGerminatingDeposits();

        uint256 pintoIn;
        // Plant earned Pinto.
        if (PINTO_PROTOCOL.balanceOfEarnedBeans(address(this)) > minSize) {
            (uint256 earnedPinto, int96 stem) = PINTO_PROTOCOL.plant();
            _addDeposit(stem, earnedPinto);
            pintoIn += earnedPinto;
        }
        // Attempt to mow if the protocol did not plant (planting invokes a mow).
        else if (PINTO_PROTOCOL.balanceOfGrownStalk(address(this), PINTO_ADDRESS) > 0) {
            PINTO_PROTOCOL.mow(address(this), PINTO_ADDRESS);
        }
        // Handle flood rewards.
        pintoIn += _handleFlood();

        if (pintoIn > 0) {
            // New vesting includes previous unvested, plus new pinto.
            vestingPinto = _unvestedAssets() + pintoIn;
            underlyingPdv += pintoIn;
            lastEarnedTimestamp = block.timestamp;
        }
    }

    /**
     * @notice Gets the highest stem that is not germinating for the Pinto token.
     * @dev Copied from protocol `getHighestNonGerminatingStem` for ease of use.
     */
    function _getHighestNonGerminatingPintoStem() internal view returns (int96) {
        return PINTO_PROTOCOL.getGerminatingStem(PINTO_ADDRESS) - 1;
    }

    /**
     * @notice Handles flood assets by swapping them to Pinto and adding them to the deposit list.
     * @dev At any given time, the magnitude of flood assets will only be a fraction of the total assets.
     *
     * - Claims flood assets if present, returns early if none are present.
     *
     * - Iterates over all wells and swaps `tranchSize` of the total asset balance at once,
     *   if the price is below the maximum flood swap trigger price and the prices are within bounds.
     *
     * - Deposits the Pinto received from the swaps and adds them to the deposit list.
     * @return pintoIn The amount of Pinto received from the swaps.
     */
    function _handleFlood() internal returns (uint256 pintoIn) {
        // Check and claim flood assets.
        _claimFloodAssets();

        if (!floodAssetsPresent) return 0;

        bool floodWellAssetsRemaining;

        address[] memory wells = PINTO_PROTOCOL.getWhitelistedWellLpTokens();
        for (uint256 i = 0; i < wells.length; i++) {
            (bool wellAssetsRemaining, uint256 pintoReceived) = _floodSwapWell(IWell(wells[i]));
            // Will be true if any well has assets remaining.
            floodWellAssetsRemaining = floodWellAssetsRemaining || wellAssetsRemaining;
            // Accumulate the total Pinto received from all well swaps.
            pintoIn += pintoReceived;
        }
        floodAssetsPresent = floodWellAssetsRemaining;

        if (pintoIn > 0) {
            (, , int96 stem) = PINTO_PROTOCOL.deposit(PINTO_ADDRESS, pintoIn, From.EXTERNAL);
            _addDeposit(stem, pintoIn);
        }
    }

    /**
     * @notice Claim flood assets if present and set the floodAssetsPresent flag.
     * Flood assets are claimed in the external balance so that they are easily swapped
     * to Pinto since wells do not support swapping from internal balances.
     */
    function _claimFloodAssets() internal {
        address[] memory wells = PINTO_PROTOCOL.getWhitelistedWellLpTokens();
        for (uint256 i = 0; i < wells.length; i++) {
            uint256 wellPlenty = PINTO_PROTOCOL.balanceOfPlenty(address(this), wells[i]);
            if (wellPlenty > 0) {
                PINTO_PROTOCOL.claimPlenty(wells[i], To.EXTERNAL);
                floodAssetsPresent = true;

                // Reset the tranch size for the asset.
                (address tokenAddr, ) = PINTO_PROTOCOL.getNonBeanTokenAndIndexFromWell(wells[i]);
                IERC20 token = IERC20(tokenAddr);
                trancheSizes[tokenAddr] =
                    (token.balanceOf(address(this)) * floodTranchRatio) /
                    1e18;
            }
        }
    }

    /**
     * @notice Handles swapping of flood assets for a single well.
     * Swaps up to `tranchSize` of the total asset balance at once after ensuring price criteria are met.
     * @param well The well to handle flood swaps for.
     * @return wellAssetsRemaining Whether the well has assets remaining after the swap.
     * @return pintoIn The amount of Pinto received from the swap.
     */
    function _floodSwapWell(
        IWell well
    ) internal returns (bool wellAssetsRemaining, uint256 pintoIn) {
        (address tokenAddr, ) = PINTO_PROTOCOL.getNonBeanTokenAndIndexFromWell(address(well));
        IERC20 token = IERC20(tokenAddr);
        uint256 balance = token.balanceOf(address(this));

        // We return false early since there are no more well flood assets remaining.
        if (balance == 0) return (false, 0);

        // Approve the well to spend the token if needed, covering all future swaps.
        if (token.allowance(address(this), address(well)) < balance) {
            token.approve(address(well), type(uint256).max);
        }

        // Check price for manipulation.
        if (
            !LibPrice._isValidSlippage(well, token, slippageRatio) ||
            !LibPrice._isValidMaxPrice(well, token, maxTriggerPrice)
        ) {
            return (true, 0);
        }

        uint256 amountToSwap = Math.min(trancheSizes[tokenAddr], balance);
        pintoIn = well.swapFrom(token, PINTO, amountToSwap, 0, address(this), type(uint256).max);

        wellAssetsRemaining = amountToSwap == balance ? false : true;
    }

    /**
     * @notice Calculate the amount of Pinto that are deposited but unvested.
     * @return assets The amount of assets that are deposited but unvested.
     */
    function _unvestedAssets() internal view returns (uint256 assets) {
        uint256 timeSinceLastClaim = block.timestamp - lastEarnedTimestamp;
        if (vestingPeriod <= timeSinceLastClaim) {
            return 0;
        }
        uint256 timeRemaining = vestingPeriod - timeSinceLastClaim;
        return (timeRemaining * vestingPinto) / vestingPeriod;
    }

    /**
     * @notice Offset for decimals between Pinto and sPinto.
     * @dev The decimals of sPinto will be 6 + the return value.
     * @return The relative increase in decimals.
     */
    function _decimalsOffset() internal pure override returns (uint8) {
        return 12;
    }

    ////////////////// MAX CHECKS //////////////////

    /**
     * @notice Check if the amount of Pinto being deposited is within the maximum limit.
     * There is currently no limit on the amount of Pinto that can be deposited.
     * @param receiver The address of the receiver of the sPinto.
     * @param assets The amount of Pinto being deposited.
     */
    function _checkMaxDeposit(address receiver, uint256 assets) internal view {
        uint256 maxAssets = maxDeposit(receiver);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxDeposit(receiver, assets, maxAssets);
        }
    }

    /**
     * @notice Check if the amount of sPinto being minted is within the maximum limit.
     * There is currently no limit on the amount of sPinto that can be minted in a single call.
     * @param receiver The address of the receiver of the sPinto.
     * @param shares The amount of sPinto being minted.
     */
    function _checkMaxMint(address receiver, uint256 shares) internal view {
        uint256 maxShares = maxMint(receiver);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxMint(receiver, shares, maxShares);
        }
    }

    /**
     * @notice Check if the amount of sPinto being burned is within the maximum limit.
     * A user can either redeem from their internal or external balance.
     * @param owner The address of the owner of the sPinto.
     * @param shares The amount of sPinto being burned.
     */
    function _checkMaxRedeem(address owner, uint256 shares, From fromMode) internal view {
        uint256 maxShares;
        if (fromMode == From.EXTERNAL) {
            maxShares = maxRedeem(owner);
        } else if (fromMode == From.INTERNAL) {
            maxShares = _maxRedeemFromInternal(owner);
        } else {
            revert InvalidMode();
        }
        if (shares > maxShares) {
            revert ERC4626ExceededMaxRedeem(owner, shares, maxShares);
        }
    }

    /**
     * @notice Returns the maximum amount of Pinto that can be withdrawn from a user's internal balance.
     * A user can redeem as much sPinto as they have in their internal balance.
     * @param owner The address of the owner of the sPinto.
     */
    function _maxRedeemFromInternal(address owner) internal view returns (uint256 internalShares) {
        internalShares = PINTO_PROTOCOL.getInternalBalance(owner, IERC20(address(this)));
    }

    /**
     * @notice Check the maximum amount of Pinto that can be withdrawn from a user.
     * A user can send shares to withdraw assets from their internal or external balance.
     * @param owner The address of the owner of the sPinto.
     * @param assets The amount of Pinto requested to withdraw.
     * @param fromMode The mode where to pull the sPinto from.
     */
    function _checkMaxWithdraw(address owner, uint256 assets, From fromMode) internal view {
        uint256 maxAssets;
        if (fromMode == From.EXTERNAL) {
            maxAssets = maxWithdraw(owner);
        } else if (fromMode == From.INTERNAL) {
            maxAssets = _maxWithdrawFromInternal(owner);
        } else {
            revert InvalidMode();
        }
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxWithdraw(owner, assets, maxAssets);
        }
    }

    /**
     * @notice Returns the maximum amount of Pinto that can be withdrawn
     * if a user sends sPinto to the contract from their internal balance.
     * @param owner The address of the owner of the sPinto.
     */
    function _maxWithdrawFromInternal(address owner) internal view returns (uint256) {
        uint256 internalShares = PINTO_PROTOCOL.getInternalBalance(owner, IERC20(address(this)));
        return previewRedeem(internalShares);
    }
}
