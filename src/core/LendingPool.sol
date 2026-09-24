// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/utils/ReentrancyGuard.sol";
import {Math} from "openzeppelin-contracts/utils/math/Math.sol";

import {BucketMath} from "../libraries/BucketMath.sol";
import {MathLib} from "../libraries/MathLib.sol";
import {InterestRateModel} from "../libraries/InterestRateModel.sol";
import {LiquidationAuction} from "../libraries/LiquidationAuction.sol";
import {IOracleAdapter} from "../interfaces/IOracleAdapter.sol";
import {MarketFactory} from "./MarketFactory.sol";
import {ProtocolConfig} from "../governance/ProtocolConfig.sol";

/// @title LendingPool
/// @notice The core protocol. Lenders supply into a specific (market, ltvTick, lltvTick)
///         bucket of their choosing -- they alone decide which collateral they'll accept and
///         at what maximum borrow LTV / liquidation LTV. Borrowers deposit collateral into a
///         market and borrow against it; the pool walks that market's bucket ladder from the
///         most conservative (lowest LTV) lenders upward, creating one "Draw" per bucket
///         actually used. A Draw permanently pairs a specific chunk of collateral with the
///         specific bucket that backed it, so liquidation is always well-defined even though
///         a single account can simultaneously hold many collateral types and many draws
///         across many markets (cross-margin at the account level, isolated-and-sound at the
///         draw level). See README.md ("Design notes") for the full rationale.
contract LendingPool is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 internal constant MAX_TICK = BucketMath.MAX_LLTV_BPS / BucketMath.TICK_SPACING_BPS; // 99

    MarketFactory public immutable marketFactory;
    ProtocolConfig public immutable config;

    struct Bucket {
        uint256 totalSupplyAssets;
        uint256 totalSupplyShares;
        uint256 totalBorrowAssets;
        uint256 totalBorrowShares;
        uint256 lastAccrue;
    }

    struct Draw {
        bytes32 marketId;
        address loanAsset;
        uint16 ltvTick;
        uint16 lltvTick;
        uint256 collateralAmount; // collateral token units backing this draw
        uint256 borrowShares; // shares in the corresponding bucket
        uint64 breachTimestamp; // 0 = healthy; else timestamp first observed underwater
    }

    // ----- loan asset registry -----
    mapping(address loanAsset => bool) public loanAssetListed;
    mapping(address loanAsset => address oracleAdapter) public loanAssetOracle;

    // ----- buckets -----
    mapping(bytes32 bucketKey => Bucket) public buckets;
    mapping(bytes32 bucketKey => mapping(address lender => uint256 shares)) public supplyShares;

    // active-tick bitmaps (Uniswap-v3-tick-style), bit i = tick i has any liquidity
    mapping(bytes32 ladderKey => uint256) public ltvActiveBitmap; // ladderKey = hash(loanAsset, marketId)
    mapping(bytes32 ltvKey => uint256) public lltvActiveBitmap; // ltvKey = hash(loanAsset, marketId, ltvTick)

    // ----- borrower accounts -----
    mapping(address owner => mapping(bytes32 marketId => uint256)) public freeCollateral;
    mapping(address owner => Draw[]) internal _draws;
    mapping(address owner => mapping(bytes32 drawKey => uint256 indexPlus1)) internal _drawIndex;

    event LoanAssetInitialized(address indexed loanAsset, address indexed oracleAdapter);
    event Supplied(
        address indexed lender,
        bytes32 indexed marketId,
        address indexed loanAsset,
        uint16 ltvTick,
        uint16 lltvTick,
        uint256 assets,
        uint256 shares
    );
    event Withdrawn(
        address indexed lender,
        bytes32 indexed marketId,
        address indexed loanAsset,
        uint16 ltvTick,
        uint16 lltvTick,
        uint256 assets,
        uint256 shares
    );
    event CollateralDeposited(address indexed owner, bytes32 indexed marketId, uint256 amount);
    event CollateralWithdrawn(address indexed owner, bytes32 indexed marketId, uint256 amount);
    event Borrowed(address indexed owner, address indexed loanAsset, bytes32 indexed marketId, uint256 amount);
    event Repaid(
        address indexed owner,
        bytes32 indexed marketId,
        address indexed loanAsset,
        uint16 ltvTick,
        uint16 lltvTick,
        uint256 assets,
        uint256 shares
    );
    event Liquidated(
        address indexed owner,
        address indexed liquidator,
        bytes32 indexed marketId,
        address loanAsset,
        uint16 ltvTick,
        uint16 lltvTick,
        uint256 repaidAssets,
        uint256 seizedCollateral
    );
    event BadDebtSocialized(address indexed owner, bytes32 indexed bucketKey, uint256 lostAssets);

    error LoanAssetNotListed();
    error LoanAssetAlreadyListed();
    error AdapterNotAllowed();
    error AdapterTokenMismatch();
    error InsufficientLiquidity();
    error NoSuchDraw();
    error NotLiquidatable();
    error InsufficientCollateral();
    error ZeroAmount();

    constructor(address _marketFactory, address _config) {
        marketFactory = MarketFactory(_marketFactory);
        config = ProtocolConfig(_config);
    }

    // ============================================================
    //                     LOAN ASSET REGISTRY
    // ============================================================

    /// @notice Permissionlessly register a loan asset for lending/borrowing. Requires a
    ///         governance-allowlisted oracle adapter (same allowlist markets use) so debt can
    ///         be valued consistently against collateral. Interest curve gets conservative
    ///         defaults; only RETUNING that curve requires governance.
    function initLoanAsset(address asset, address oracleAdapter) external {
        if (loanAssetListed[asset]) revert LoanAssetAlreadyListed();
        if (!config.isAdapterAllowed(oracleAdapter)) revert AdapterNotAllowed();
        if (IOracleAdapter(oracleAdapter).token() != asset) revert AdapterTokenMismatch();

        loanAssetListed[asset] = true;
        loanAssetOracle[asset] = oracleAdapter;
        config.initDefaultRateModel(asset);

        emit LoanAssetInitialized(asset, oracleAdapter);
    }

    // ============================================================
    //                          LENDING
    // ============================================================

    /// @notice Supply `amount` of `loanAsset` into the bucket for `marketId` at the caller's
    ///         chosen max-borrow-LTV and liquidation-LTV. This is the entire risk-management
    ///         decision in the protocol: which collateral, and how much leverage against it.
    function supply(bytes32 marketId, address loanAsset, uint16 ltvBps, uint16 lltvBps, uint256 amount)
        external
        nonReentrant
        returns (uint256 shares)
    {
        if (amount == 0) revert ZeroAmount();
        if (!loanAssetListed[loanAsset]) revert LoanAssetNotListed();
        marketFactory.getMarket(marketId); // reverts if market doesn't exist

        (uint16 ltvTick, uint16 lltvTick) = BucketMath.validateAndTick(ltvBps, lltvBps);
        bytes32 bKey = BucketMath.bucketKey(marketId, loanAsset, ltvTick, lltvTick);
        _accrueBucket(bKey, loanAsset);
        Bucket storage b = buckets[bKey];

        bool wasEmpty = b.totalSupplyAssets == 0;
        shares = MathLib.toSharesDown(amount, b.totalSupplyAssets, b.totalSupplyShares);

        b.totalSupplyAssets += amount;
        b.totalSupplyShares += shares;
        supplyShares[bKey][msg.sender] += shares;

        if (wasEmpty) _activateTicks(loanAsset, marketId, ltvTick, lltvTick);

        IERC20(loanAsset).safeTransferFrom(msg.sender, address(this), amount);
        emit Supplied(msg.sender, marketId, loanAsset, ltvTick, lltvTick, amount, shares);
    }

    /// @notice Withdraw previously supplied liquidity from a specific bucket. Limited to the
    ///         bucket's currently un-borrowed assets, like any pooled lending design.
    function withdraw(bytes32 marketId, address loanAsset, uint16 ltvBps, uint16 lltvBps, uint256 shares)
        external
        nonReentrant
        returns (uint256 assets)
    {
        if (shares == 0) revert ZeroAmount();
        (uint16 ltvTick, uint16 lltvTick) = BucketMath.validateAndTick(ltvBps, lltvBps);
        bytes32 bKey = BucketMath.bucketKey(marketId, loanAsset, ltvTick, lltvTick);
        _accrueBucket(bKey, loanAsset);
        Bucket storage b = buckets[bKey];

        assets = MathLib.toAssetsDown(shares, b.totalSupplyAssets, b.totalSupplyShares);
        if (assets > b.totalSupplyAssets - b.totalBorrowAssets) revert InsufficientLiquidity();

        supplyShares[bKey][msg.sender] -= shares;
        b.totalSupplyShares -= shares;
        b.totalSupplyAssets -= assets;

        if (b.totalSupplyAssets == 0) _deactivateTicks(loanAsset, marketId, ltvTick, lltvTick);

        IERC20(loanAsset).safeTransfer(msg.sender, assets);
        emit Withdrawn(msg.sender, marketId, loanAsset, ltvTick, lltvTick, assets, shares);
    }

    // ============================================================
    //                     COLLATERAL / BORROW
    // ============================================================

    function depositCollateral(bytes32 marketId, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        MarketFactory.Market memory mkt = marketFactory.getMarket(marketId);
        freeCollateral[msg.sender][marketId] += amount;
        IERC20(mkt.collateralToken).safeTransferFrom(msg.sender, address(this), amount);
        emit CollateralDeposited(msg.sender, marketId, amount);
    }

    /// @notice Withdraw collateral that is not currently backing any draw in this market.
    function withdrawCollateral(bytes32 marketId, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (freeCollateral[msg.sender][marketId] < amount) revert InsufficientCollateral();
        freeCollateral[msg.sender][marketId] -= amount;
        MarketFactory.Market memory mkt = marketFactory.getMarket(marketId);
        IERC20(mkt.collateralToken).safeTransfer(msg.sender, amount);
        emit CollateralWithdrawn(msg.sender, marketId, amount);
    }

    /// @notice Borrow `amount` of `loanAsset` against the caller's free (unallocated)
    ///         collateral in `marketId`. Walks the market's bucket ladder from the lowest
    ///         (safest, cheapest) active LTV tick upward, only drawing from buckets whose
    ///         lenders explicitly opted into this exact collateral market, until `amount` is
    ///         filled or the ladder + free collateral are exhausted.
    function borrow(address loanAsset, bytes32 marketId, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (!loanAssetListed[loanAsset]) revert LoanAssetNotListed();
        MarketFactory.Market memory mkt = marketFactory.getMarket(marketId);

        PriceCtx memory ctx = _loadPriceCtx(mkt.collateralToken, mkt.oracleAdapter, loanAsset);

        uint256 remaining = amount;
        bytes32 ladderKey = keccak256(abi.encode(loanAsset, marketId));
        uint256 ltvBitmap = ltvActiveBitmap[ladderKey];

        for (uint16 ltvTick = 0; ltvTick <= MAX_TICK && remaining > 0; ltvTick++) {
            if ((ltvBitmap >> ltvTick) & 1 == 0) continue;
            if (freeCollateral[msg.sender][marketId] == 0) break;

            bytes32 ltvKey = keccak256(abi.encode(loanAsset, marketId, ltvTick));
            uint256 lltvBitmap = lltvActiveBitmap[ltvKey];

            for (uint16 lltvTick = ltvTick; lltvTick <= MAX_TICK && remaining > 0; lltvTick++) {
                if ((lltvBitmap >> lltvTick) & 1 == 0) continue;

                remaining = _drawFromBucket(msg.sender, marketId, loanAsset, ltvTick, lltvTick, remaining, ctx);
                if (freeCollateral[msg.sender][marketId] == 0) break;
            }
        }

        if (remaining > 0) revert InsufficientLiquidity();
        IERC20(loanAsset).safeTransfer(msg.sender, amount);
        emit Borrowed(msg.sender, loanAsset, marketId, amount);
    }

    struct PriceCtx {
        uint256 collPrice18;
        uint256 loanPrice18;
        uint8 collDecimals;
        uint8 loanDecimals;
    }

    function _loadPriceCtx(address collateralToken, address oracleAdapter, address loanAsset)
        internal
        view
        returns (PriceCtx memory ctx)
    {
        ctx.collPrice18 = IOracleAdapter(oracleAdapter).getPrice();
        ctx.loanPrice18 = IOracleAdapter(loanAssetOracle[loanAsset]).getPrice();
        ctx.collDecimals = IERC20Metadata(collateralToken).decimals();
        ctx.loanDecimals = IERC20Metadata(loanAsset).decimals();
    }

    function _drawFromBucket(
        address owner,
        bytes32 marketId,
        address loanAsset,
        uint16 ltvTick,
        uint16 lltvTick,
        uint256 remaining,
        PriceCtx memory ctx
    ) internal returns (uint256) {
        bytes32 bKey = BucketMath.bucketKey(marketId, loanAsset, ltvTick, lltvTick);
        _accrueBucket(bKey, loanAsset);
        Bucket storage b = buckets[bKey];

        uint256 available = b.totalSupplyAssets - b.totalBorrowAssets;
        if (available == 0) return remaining;

        uint256 freeColl = freeCollateral[owner][marketId];
        if (freeColl == 0) return remaining;

        uint256 ltvBpsVal = BucketMath.toBps(ltvTick);
        uint256 collValue18 = Math.mulDiv(freeColl, ctx.collPrice18, 10 ** ctx.collDecimals);
        uint256 maxDebtValue18 = Math.mulDiv(collValue18, ltvBpsVal, BucketMath.BPS_DENOMINATOR);
        uint256 maxDebtLoanUnits = Math.mulDiv(maxDebtValue18, 10 ** ctx.loanDecimals, ctx.loanPrice18);

        uint256 drawAmount = Math.min(available, Math.min(remaining, maxDebtLoanUnits));
        if (drawAmount == 0) return remaining;

        uint256 drawValue18 = Math.mulDiv(drawAmount, ctx.loanPrice18, 10 ** ctx.loanDecimals);
        uint256 collateralNeededValue18 = Math.mulDiv(drawValue18, BucketMath.BPS_DENOMINATOR, ltvBpsVal);
        uint256 collateralReserved = Math.mulDiv(collateralNeededValue18, 10 ** ctx.collDecimals, ctx.collPrice18);
        if (collateralReserved > freeColl) collateralReserved = freeColl; // rounding guard

        uint256 borrowShares = MathLib.toSharesUp(drawAmount, b.totalBorrowAssets, b.totalBorrowShares);
        b.totalBorrowShares += borrowShares;
        b.totalBorrowAssets += drawAmount;

        freeCollateral[owner][marketId] -= collateralReserved;
        _addOrUpdateDraw(owner, marketId, loanAsset, ltvTick, lltvTick, collateralReserved, borrowShares);

        return remaining - drawAmount;
    }

    // ============================================================
    //                       REPAY / LIQUIDATE
    // ============================================================

    function repay(bytes32 marketId, address loanAsset, uint16 ltvBps, uint16 lltvBps, uint256 amount)
        external
        nonReentrant
        returns (uint256 actualRepay)
    {
        if (amount == 0) revert ZeroAmount();
        (uint16 ltvTick, uint16 lltvTick) = BucketMath.validateAndTick(ltvBps, lltvBps);
        bytes32 key = keccak256(abi.encode(marketId, loanAsset, ltvTick, lltvTick));
        uint256 idxPlus1 = _drawIndex[msg.sender][key];
        if (idxPlus1 == 0) revert NoSuchDraw();
        Draw storage d = _draws[msg.sender][idxPlus1 - 1];

        bytes32 bKey = BucketMath.bucketKey(marketId, loanAsset, ltvTick, lltvTick);
        _accrueBucket(bKey, loanAsset);
        Bucket storage b = buckets[bKey];

        uint256 debtAssets = MathLib.toAssetsUp(d.borrowShares, b.totalBorrowAssets, b.totalBorrowShares);
        actualRepay = Math.min(amount, debtAssets);
        uint256 repayShares = MathLib.toSharesDown(actualRepay, b.totalBorrowAssets, b.totalBorrowShares);
        if (repayShares > d.borrowShares) repayShares = d.borrowShares;

        b.totalBorrowShares -= repayShares;
        b.totalBorrowAssets -= actualRepay;

        uint256 originalShares = d.borrowShares;
        d.borrowShares = originalShares - repayShares;

        uint256 releasedCollateral =
            d.borrowShares == 0 ? d.collateralAmount : Math.mulDiv(d.collateralAmount, repayShares, originalShares);
        d.collateralAmount -= releasedCollateral;
        freeCollateral[msg.sender][marketId] += releasedCollateral;

        if (d.borrowShares == 0) {
            _removeDraw(msg.sender, key);
        } else {
            d.breachTimestamp = 0; // a partial repay always improves LTV since collateral is
                // released pro-rata with debt; the draw's LTV ratio is therefore unchanged by
                // a partial repay in this model, so if it was healthy before it stays healthy.
        }

        IERC20(loanAsset).safeTransferFrom(msg.sender, address(this), actualRepay);
        emit Repaid(msg.sender, marketId, loanAsset, ltvTick, lltvTick, actualRepay, repayShares);
    }

    /// @notice Liquidate a specific underwater draw. Bonus follows the systemic Dutch-auction
    ///         curve in ProtocolConfig -- never lender-configurable. If the draw's collateral
    ///         is insufficient to cover the full bonus (deep bad debt), the liquidator simply
    ///         receives whatever collateral remains; use `socializeBadDebt` afterward to
    ///         write down the bucket's remaining debt.
    function liquidate(
        address owner,
        bytes32 marketId,
        address loanAsset,
        uint16 ltvBps,
        uint16 lltvBps,
        uint256 repayAmount
    ) external nonReentrant returns (uint256 actualRepay, uint256 seizedCollateral) {
        (uint16 ltvTick, uint16 lltvTick) = BucketMath.validateAndTick(ltvBps, lltvBps);
        bytes32 key = keccak256(abi.encode(marketId, loanAsset, ltvTick, lltvTick));
        uint256 idxPlus1 = _drawIndex[owner][key];
        if (idxPlus1 == 0) revert NoSuchDraw();
        Draw storage d = _draws[owner][idxPlus1 - 1];

        bytes32 bKey = BucketMath.bucketKey(marketId, loanAsset, ltvTick, lltvTick);
        _accrueBucket(bKey, loanAsset);
        Bucket storage b = buckets[bKey];

        MarketFactory.Market memory mkt = marketFactory.getMarket(marketId);
        PriceCtx memory ctx = _loadPriceCtx(mkt.collateralToken, mkt.oracleAdapter, loanAsset);

        uint256 debtAssets = MathLib.toAssetsUp(d.borrowShares, b.totalBorrowAssets, b.totalBorrowShares);
        uint256 currentLtvBps = _ltvBpsOf(d.collateralAmount, debtAssets, ctx);
        uint256 lltvBpsVal = BucketMath.toBps(lltvTick);
        if (currentLtvBps <= lltvBpsVal) revert NotLiquidatable();

        if (d.breachTimestamp == 0) d.breachTimestamp = uint64(block.timestamp);

        ProtocolConfig.LiquidationAuctionParams memory lp = config.getLiquidationParams();
        uint256 bonusWad = LiquidationAuction.currentBonusWad(lp, block.timestamp - d.breachTimestamp);

        actualRepay = Math.min(repayAmount, debtAssets);
        uint256 repayShares = MathLib.toSharesDown(actualRepay, b.totalBorrowAssets, b.totalBorrowShares);
        if (repayShares > d.borrowShares) repayShares = d.borrowShares;

        uint256 repayValue18 = Math.mulDiv(actualRepay, ctx.loanPrice18, 10 ** ctx.loanDecimals);
        uint256 seizeValue18 = repayValue18 + MathLib.wadMul(repayValue18, bonusWad);
        seizedCollateral = Math.mulDiv(seizeValue18, 10 ** ctx.collDecimals, ctx.collPrice18);
        if (seizedCollateral > d.collateralAmount) seizedCollateral = d.collateralAmount; // bad-debt cap

        b.totalBorrowShares -= repayShares;
        b.totalBorrowAssets -= actualRepay;
        d.borrowShares -= repayShares;
        d.collateralAmount -= seizedCollateral;

        if (d.borrowShares == 0) {
            // Fully repaid by this liquidation. Any leftover collateral belongs back to the
            // owner as free collateral -- it must never simply be deleted along with the draw.
            if (d.collateralAmount > 0) {
                freeCollateral[owner][marketId] += d.collateralAmount;
                d.collateralAmount = 0;
            }
            _removeDraw(owner, key);
        } else if (d.collateralAmount == 0) {
            // Bad debt: the draw has debt but nothing left to seize. It must persist (not be
            // deleted) so `socializeBadDebt` can later write down the bucket's remaining
            // assets -- deleting it here would silently erase the loss instead of accounting
            // for it. breachTimestamp is left as-is (already breached).
        } else {
            uint256 newDebt = MathLib.toAssetsUp(d.borrowShares, b.totalBorrowAssets, b.totalBorrowShares);
            uint256 newLtv = _ltvBpsOf(d.collateralAmount, newDebt, ctx);
            d.breachTimestamp = newLtv <= lltvBpsVal ? 0 : d.breachTimestamp;
        }

        IERC20(loanAsset).safeTransferFrom(msg.sender, address(this), actualRepay);
        IERC20(mkt.collateralToken).safeTransfer(msg.sender, seizedCollateral);

        emit Liquidated(owner, msg.sender, marketId, loanAsset, ltvTick, lltvTick, actualRepay, seizedCollateral);
    }

    /// @notice After a liquidation leaves a draw with debt but zero collateral, anyone may
    ///         call this to write down the bucket's outstanding assets by the remaining debt.
    ///         The loss is borne only by lenders in THIS bucket (this exact market + LTV/LLTV
    ///         choice), never by lenders in other buckets or other markets -- the isolation
    ///         property the whole design is built around.
    function socializeBadDebt(address owner, bytes32 marketId, address loanAsset, uint16 ltvBps, uint16 lltvBps)
        external
        nonReentrant
    {
        (uint16 ltvTick, uint16 lltvTick) = BucketMath.validateAndTick(ltvBps, lltvBps);
        bytes32 key = keccak256(abi.encode(marketId, loanAsset, ltvTick, lltvTick));
        uint256 idxPlus1 = _drawIndex[owner][key];
        if (idxPlus1 == 0) revert NoSuchDraw();
        Draw storage d = _draws[owner][idxPlus1 - 1];
        require(d.collateralAmount == 0 && d.borrowShares > 0, "not bad debt");

        bytes32 bKey = BucketMath.bucketKey(marketId, loanAsset, ltvTick, lltvTick);
        _accrueBucket(bKey, loanAsset);
        Bucket storage b = buckets[bKey];

        uint256 debtAssets = MathLib.toAssetsUp(d.borrowShares, b.totalBorrowAssets, b.totalBorrowShares);
        b.totalBorrowShares -= d.borrowShares;
        b.totalBorrowAssets -= debtAssets;
        b.totalSupplyAssets = b.totalSupplyAssets > debtAssets ? b.totalSupplyAssets - debtAssets : 0;

        _removeDraw(owner, key);
        emit BadDebtSocialized(owner, bKey, debtAssets);
    }

    // ============================================================
    //                          INTERNAL
    // ============================================================

    function _accrueBucket(bytes32 bKey, address loanAsset) internal {
        Bucket storage b = buckets[bKey];
        uint256 last = b.lastAccrue;
        if (last == 0) {
            b.lastAccrue = block.timestamp;
            return;
        }
        uint256 elapsed = block.timestamp - last;
        if (elapsed == 0) return;
        b.lastAccrue = block.timestamp;

        if (b.totalBorrowAssets == 0 || b.totalSupplyAssets == 0) return;

        ProtocolConfig.RateModelParams memory p = config.getRateModelParams(loanAsset);
        uint256 util = InterestRateModel.utilizationWad(b.totalBorrowAssets, b.totalSupplyAssets);
        uint256 rate = InterestRateModel.getBorrowRateWad(p, util);
        uint256 growth = InterestRateModel.growthFactorWad(rate, elapsed);

        uint256 newBorrowAssets = MathLib.wadMul(b.totalBorrowAssets, growth);
        uint256 interest = newBorrowAssets - b.totalBorrowAssets;

        b.totalBorrowAssets = newBorrowAssets;
        b.totalSupplyAssets += interest; // 100% of interest to suppliers; no protocol fee in v1
    }

    function _activateTicks(address loanAsset, bytes32 marketId, uint16 ltvTick, uint16 lltvTick) internal {
        bytes32 ladderKey = keccak256(abi.encode(loanAsset, marketId));
        ltvActiveBitmap[ladderKey] |= (uint256(1) << ltvTick);
        bytes32 ltvKey = keccak256(abi.encode(loanAsset, marketId, ltvTick));
        lltvActiveBitmap[ltvKey] |= (uint256(1) << lltvTick);
    }

    function _deactivateTicks(address loanAsset, bytes32 marketId, uint16 ltvTick, uint16 lltvTick) internal {
        bytes32 ltvKey = keccak256(abi.encode(loanAsset, marketId, ltvTick));
        lltvActiveBitmap[ltvKey] &= ~(uint256(1) << lltvTick);
        if (lltvActiveBitmap[ltvKey] == 0) {
            bytes32 ladderKey = keccak256(abi.encode(loanAsset, marketId));
            ltvActiveBitmap[ladderKey] &= ~(uint256(1) << ltvTick);
        }
    }

    function _addOrUpdateDraw(
        address owner,
        bytes32 marketId,
        address loanAsset,
        uint16 ltvTick,
        uint16 lltvTick,
        uint256 addCollateral,
        uint256 addBorrowShares
    ) internal {
        bytes32 key = keccak256(abi.encode(marketId, loanAsset, ltvTick, lltvTick));
        uint256 idxPlus1 = _drawIndex[owner][key];
        if (idxPlus1 == 0) {
            _draws[owner].push(
                Draw({
                    marketId: marketId,
                    loanAsset: loanAsset,
                    ltvTick: ltvTick,
                    lltvTick: lltvTick,
                    collateralAmount: addCollateral,
                    borrowShares: addBorrowShares,
                    breachTimestamp: 0
                })
            );
            _drawIndex[owner][key] = _draws[owner].length;
        } else {
            Draw storage d = _draws[owner][idxPlus1 - 1];
            d.collateralAmount += addCollateral;
            d.borrowShares += addBorrowShares;
        }
    }

    /// @dev Swap-pop removal; updates the moved draw's index pointer.
    function _removeDraw(address owner, bytes32 key) internal {
        uint256 idxPlus1 = _drawIndex[owner][key];
        uint256 lastIdx = _draws[owner].length - 1;
        uint256 idx = idxPlus1 - 1;

        if (idx != lastIdx) {
            Draw memory moved = _draws[owner][lastIdx];
            _draws[owner][idx] = moved;
            bytes32 movedKey =
                keccak256(abi.encode(moved.marketId, moved.loanAsset, moved.ltvTick, moved.lltvTick));
            _drawIndex[owner][movedKey] = idx + 1;
        }
        _draws[owner].pop();
        delete _drawIndex[owner][key];
    }

    function _ltvBpsOf(uint256 collateralAmount, uint256 debtAssets, PriceCtx memory ctx)
        internal
        pure
        returns (uint256)
    {
        if (collateralAmount == 0) return type(uint256).max;
        uint256 collValue18 = Math.mulDiv(collateralAmount, ctx.collPrice18, 10 ** ctx.collDecimals);
        if (collValue18 == 0) return type(uint256).max;
        uint256 debtValue18 = Math.mulDiv(debtAssets, ctx.loanPrice18, 10 ** ctx.loanDecimals);
        return Math.mulDiv(debtValue18, BucketMath.BPS_DENOMINATOR, collValue18);
    }

    // ============================================================
    //                            VIEWS
    // ============================================================

    function getDraws(address owner) external view returns (Draw[] memory) {
        return _draws[owner];
    }

    function getDraw(address owner, bytes32 marketId, address loanAsset, uint16 ltvTick, uint16 lltvTick)
        external
        view
        returns (Draw memory)
    {
        bytes32 key = keccak256(abi.encode(marketId, loanAsset, ltvTick, lltvTick));
        uint256 idxPlus1 = _drawIndex[owner][key];
        if (idxPlus1 == 0) revert NoSuchDraw();
        return _draws[owner][idxPlus1 - 1];
    }

    function previewDebt(bytes32 marketId, address loanAsset, uint16 ltvTick, uint16 lltvTick, address owner)
        external
        view
        returns (uint256 debtAssets)
    {
        bytes32 key = keccak256(abi.encode(marketId, loanAsset, ltvTick, lltvTick));
        uint256 idxPlus1 = _drawIndex[owner][key];
        if (idxPlus1 == 0) return 0;
        Draw storage d = _draws[owner][idxPlus1 - 1];
        bytes32 bKey = BucketMath.bucketKey(marketId, loanAsset, ltvTick, lltvTick);
        (uint256 simBorrowAssets, uint256 simBorrowShares) = _simulateAccrual(bKey, loanAsset);
        debtAssets = MathLib.toAssetsUp(d.borrowShares, simBorrowAssets, simBorrowShares);
    }

    /// @dev Read-only projection of what `_accrueBucket` would do, without writing state.
    ///      Lets views (and UIs) show live, up-to-the-second debt instead of a stale snapshot
    ///      that only updates on the next actual interaction with the bucket.
    function _simulateAccrual(bytes32 bKey, address loanAsset)
        internal
        view
        returns (uint256 simBorrowAssets, uint256 simBorrowShares)
    {
        Bucket storage b = buckets[bKey];
        simBorrowAssets = b.totalBorrowAssets;
        simBorrowShares = b.totalBorrowShares;

        uint256 last = b.lastAccrue;
        if (last == 0 || b.totalBorrowAssets == 0 || b.totalSupplyAssets == 0) return (simBorrowAssets, simBorrowShares);
        uint256 elapsed = block.timestamp - last;
        if (elapsed == 0) return (simBorrowAssets, simBorrowShares);

        ProtocolConfig.RateModelParams memory p = config.getRateModelParams(loanAsset);
        uint256 util = InterestRateModel.utilizationWad(b.totalBorrowAssets, b.totalSupplyAssets);
        uint256 rate = InterestRateModel.getBorrowRateWad(p, util);
        uint256 growth = InterestRateModel.growthFactorWad(rate, elapsed);
        simBorrowAssets = MathLib.wadMul(b.totalBorrowAssets, growth);
        // shares are unaffected by accrual; only the assets-per-share ratio changes
    }

    function bucketUtilizationWad(bytes32 marketId, address loanAsset, uint16 ltvTick, uint16 lltvTick)
        external
        view
        returns (uint256)
    {
        Bucket storage b = buckets[BucketMath.bucketKey(marketId, loanAsset, ltvTick, lltvTick)];
        return InterestRateModel.utilizationWad(b.totalBorrowAssets, b.totalSupplyAssets);
    }
}
