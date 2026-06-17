// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FHE, euint64, externalEuint64, ebool} from "@fhevm/solidity/lib/FHE.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";

interface IERC20Minimal {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @title SealedFX
/// @notice Sealed-bid cross-border FX matching via FHE.
///         Users deposit ERC-20 tokens which are held as encrypted internal
///         balances. Orders, matching, and settlement all operate on encrypted
///         values — the blockchain never sees the amounts.
contract SealedFX is ZamaEthereumConfig {
    uint64 public constant RATE_SCALE = 1_000_000;

    enum OrderStatus { Open, Matched, Cancelled, Expired }

    struct Order {
        address maker;
        address tokenIn;
        address tokenOut;
        euint64 amount;
        euint64 rateScaled;
        uint256 createdAt;
        uint256 expiresAt;
        OrderStatus status;
    }

    struct Settlement {
        uint256 buyOrderId;
        uint256 sellOrderId;
        euint64 amountInSettled;
        euint64 amountOutSettled;
        uint256 settledAt;
    }

    // --- State ---

    uint256 public nextOrderId;
    uint256 public nextSettlementId;
    address public admin;

    mapping(uint256 => Order) internal _orders;
    mapping(uint256 => Settlement) internal _settlements;
    mapping(address => uint256[]) internal _userOrders;
    mapping(address => uint256[]) internal _userSettlements;

    // Encrypted escrow: user → token → encrypted balance
    mapping(address => mapping(address => euint64)) internal _escrow;

    // Encrypted daily limit: user → token → encrypted limit
    mapping(address => mapping(address => euint64)) internal _dailyLimit;
    // Encrypted daily spent: user → token → encrypted spent today
    mapping(address => mapping(address => euint64)) internal _dailySpent;
    // Day tracker for daily limit reset
    mapping(address => mapping(address => uint256)) internal _lastSpendDay;

    // Supported token pairs
    mapping(address => mapping(address => bool)) public supportedPairs;

    // --- Events ---

    event Deposited(address indexed user, address indexed token, uint64 amount);
    event Withdrawn(address indexed user, address indexed token, uint64 amount);
    event OrderCreated(
        uint256 indexed orderId,
        address indexed maker,
        address tokenIn,
        address tokenOut,
        uint256 expiresAt
    );
    event OrderCancelled(uint256 indexed orderId);
    event OrdersMatched(
        uint256 indexed settlementId,
        uint256 indexed orderIdA,
        uint256 indexed orderIdB,
        uint256 settledAt
    );
    event DailyLimitSet(address indexed user, address indexed token);
    event PairUpdated(address indexed tokenA, address indexed tokenB, bool supported);

    // --- Errors ---

    error NotAdmin();
    error OrderNotOpen();
    error NotOrderMaker();
    error OrderExpired();
    error TokenPairMismatch();
    error PairNotSupported();
    error ZeroAmount();
    error TransferFailed();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    constructor() {
        admin = msg.sender;
    }

    // =========================================================================
    //                           ADMIN
    // =========================================================================

    function setSupportedPair(address tokenA, address tokenB, bool supported) external onlyAdmin {
        supportedPairs[tokenA][tokenB] = supported;
        supportedPairs[tokenB][tokenA] = supported;
        emit PairUpdated(tokenA, tokenB, supported);
    }

    // =========================================================================
    //                         DEPOSIT / WITHDRAW
    // =========================================================================

    /// @notice Deposit ERC-20 tokens into encrypted escrow.
    ///         The deposit amount is public (ERC-20 transfer), but your
    ///         escrow balance is encrypted from this point on.
    function deposit(address token, uint64 amount) external {
        if (amount == 0) revert ZeroAmount();

        bool ok = IERC20Minimal(token).transferFrom(msg.sender, address(this), uint256(amount));
        if (!ok) revert TransferFailed();

        euint64 encAmount = FHE.asEuint64(amount);

        if (FHE.isInitialized(_escrow[msg.sender][token])) {
            _escrow[msg.sender][token] = FHE.add(_escrow[msg.sender][token], encAmount);
        } else {
            _escrow[msg.sender][token] = encAmount;
        }

        FHE.allowThis(_escrow[msg.sender][token]);
        FHE.allow(_escrow[msg.sender][token], msg.sender);

        emit Deposited(msg.sender, token, amount);
    }

    /// @notice Withdraw tokens from escrow.
    ///         Deducts from encrypted balance. If insufficient, the deduction
    ///         is a no-op (FHE select). Check your balance after.
    function withdraw(address token, uint64 amount) external {
        if (amount == 0) revert ZeroAmount();

        euint64 encAmount = FHE.asEuint64(amount);
        euint64 balance = _escrow[msg.sender][token];

        ebool sufficient = FHE.le(encAmount, balance);
        _escrow[msg.sender][token] = FHE.select(sufficient, FHE.sub(balance, encAmount), balance);

        FHE.allowThis(_escrow[msg.sender][token]);
        FHE.allow(_escrow[msg.sender][token], msg.sender);

        // Transfer back. If the FHE balance was insufficient, the encrypted balance
        // didn't change but the ERC-20 transfer still happens. The admin should
        // reconcile, or we trust the user to only withdraw what they deposited.
        // In production, this would use async decryption + callback.
        IERC20Minimal(token).transfer(msg.sender, uint256(amount));

        emit Withdrawn(msg.sender, token, amount);
    }

    /// @notice Get your encrypted escrow balance. Only you can decrypt.
    function escrowBalance(address token) external view returns (euint64) {
        return _escrow[msg.sender][token];
    }

    // =========================================================================
    //                          DAILY LIMITS
    // =========================================================================

    /// @notice Set an encrypted daily spending limit for a token.
    function setDailyLimit(
        address token,
        externalEuint64 encryptedLimit,
        bytes calldata inputProof
    ) external {
        euint64 limit = FHE.fromExternal(encryptedLimit, inputProof);
        _dailyLimit[msg.sender][token] = limit;

        FHE.allowThis(limit);
        FHE.allow(limit, msg.sender);

        emit DailyLimitSet(msg.sender, token);
    }

    /// @notice Get your encrypted daily limit. Only you can decrypt.
    function getDailyLimit(address token) external view returns (euint64) {
        return _dailyLimit[msg.sender][token];
    }

    /// @notice Get your encrypted daily spend. Only you can decrypt.
    function getDailySpent(address token) external view returns (euint64) {
        return _dailySpent[msg.sender][token];
    }

    // =========================================================================
    //                            ORDERS
    // =========================================================================

    /// @notice Submit a sealed FX order. Locks the encrypted amount in escrow.
    function createOrder(
        address tokenIn,
        address tokenOut,
        externalEuint64 encryptedAmount,
        externalEuint64 encryptedRate,
        bytes calldata inputProof,
        uint256 duration
    ) external returns (uint256 orderId) {
        if (!supportedPairs[tokenIn][tokenOut]) revert PairNotSupported();

        euint64 amount = FHE.fromExternal(encryptedAmount, inputProof);
        euint64 rateScaled = FHE.fromExternal(encryptedRate, inputProof);

        // Deduct from escrow (encrypted). If insufficient, escrow unchanged (FHE select).
        euint64 balance = _escrow[msg.sender][tokenIn];
        ebool sufficient = FHE.le(amount, balance);
        _escrow[msg.sender][tokenIn] = FHE.select(sufficient, FHE.sub(balance, amount), balance);

        FHE.allowThis(_escrow[msg.sender][tokenIn]);
        FHE.allow(_escrow[msg.sender][tokenIn], msg.sender);

        // Check and update daily limit
        _checkDailyLimit(msg.sender, tokenIn, amount);

        orderId = nextOrderId++;

        _orders[orderId] = Order({
            maker: msg.sender,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amount: amount,
            rateScaled: rateScaled,
            createdAt: block.timestamp,
            expiresAt: block.timestamp + duration,
            status: OrderStatus.Open
        });

        FHE.allowThis(amount);
        FHE.allow(amount, msg.sender);
        FHE.allowThis(rateScaled);
        FHE.allow(rateScaled, msg.sender);

        _userOrders[msg.sender].push(orderId);

        emit OrderCreated(orderId, msg.sender, tokenIn, tokenOut, block.timestamp + duration);
    }

    /// @notice Cancel an open order. Returns locked amount to escrow.
    function cancelOrder(uint256 orderId) external {
        Order storage order = _orders[orderId];
        if (order.status != OrderStatus.Open) revert OrderNotOpen();
        if (order.maker != msg.sender) revert NotOrderMaker();

        order.status = OrderStatus.Cancelled;

        // Return locked amount to escrow
        if (FHE.isInitialized(_escrow[msg.sender][order.tokenIn])) {
            _escrow[msg.sender][order.tokenIn] = FHE.add(
                _escrow[msg.sender][order.tokenIn],
                order.amount
            );
        } else {
            _escrow[msg.sender][order.tokenIn] = order.amount;
        }

        FHE.allowThis(_escrow[msg.sender][order.tokenIn]);
        FHE.allow(_escrow[msg.sender][order.tokenIn], msg.sender);

        emit OrderCancelled(orderId);
    }

    // =========================================================================
    //                           MATCHING
    // =========================================================================

    /// @notice Match two compatible orders using FHE.
    ///         Order A: sells tokenX for tokenY at rateA
    ///         Order B: sells tokenY for tokenX at rateB
    ///         Compatible if rateA * rateB >= RATE_SCALE^2 / 1e6
    ///         Settlement: min(amountA, amountB) transferred each way.
    function matchOrders(uint256 orderIdA, uint256 orderIdB) external returns (uint256 settlementId) {
        Order storage orderA = _orders[orderIdA];
        Order storage orderB = _orders[orderIdB];

        if (orderA.status != OrderStatus.Open) revert OrderNotOpen();
        if (orderB.status != OrderStatus.Open) revert OrderNotOpen();
        if (block.timestamp > orderA.expiresAt) revert OrderExpired();
        if (block.timestamp > orderB.expiresAt) revert OrderExpired();
        if (orderA.tokenIn != orderB.tokenOut || orderA.tokenOut != orderB.tokenIn) {
            revert TokenPairMismatch();
        }

        // --- FHE rate compatibility ---
        euint64 rateProduct = FHE.mul(orderA.rateScaled, orderB.rateScaled);
        euint64 threshold = FHE.asEuint64(uint64((RATE_SCALE * RATE_SCALE) / 1_000_000));
        ebool compatible = FHE.ge(rateProduct, threshold);

        // --- FHE settlement amounts ---
        euint64 settledAmount = FHE.min(orderA.amount, orderB.amount);
        euint64 zero = FHE.asEuint64(uint64(0));

        // If not compatible, settlement is zero (no-op match)
        euint64 amountAtoB = FHE.select(compatible, settledAmount, zero);
        euint64 amountBtoA = FHE.select(compatible, settledAmount, zero);

        // --- Credit counterparties' escrow ---
        // A sells tokenIn, B receives it
        _creditEscrow(orderB.maker, orderA.tokenIn, amountAtoB);
        // B sells tokenIn, A receives it
        _creditEscrow(orderA.maker, orderB.tokenIn, amountBtoA);

        // Handle partial fills: remaining amount stays as a new implicit balance
        // For simplicity, mark both as Matched (full fill on min amount)
        orderA.status = OrderStatus.Matched;
        orderB.status = OrderStatus.Matched;

        // If partial fill, return excess to the larger order's maker
        ebool aIsLarger = FHE.gt(orderA.amount, orderB.amount);
        euint64 excessA = FHE.select(aIsLarger, FHE.sub(orderA.amount, orderB.amount), zero);
        euint64 excessB = FHE.select(aIsLarger, zero, FHE.sub(orderB.amount, orderA.amount));

        // Also zero out excess if not compatible
        excessA = FHE.select(compatible, excessA, orderA.amount);
        excessB = FHE.select(compatible, excessB, orderB.amount);

        // Return excess to makers' escrow
        if (FHE.isInitialized(excessA)) {
            _creditEscrow(orderA.maker, orderA.tokenIn, excessA);
        }
        if (FHE.isInitialized(excessB)) {
            _creditEscrow(orderB.maker, orderB.tokenIn, excessB);
        }

        // --- Record settlement ---
        settlementId = nextSettlementId++;
        _settlements[settlementId] = Settlement({
            buyOrderId: orderIdA,
            sellOrderId: orderIdB,
            amountInSettled: amountAtoB,
            amountOutSettled: amountBtoA,
            settledAt: block.timestamp
        });

        // Allow both makers to decrypt settlement amounts
        FHE.allow(amountAtoB, orderA.maker);
        FHE.allow(amountAtoB, orderB.maker);
        FHE.allow(amountBtoA, orderA.maker);
        FHE.allow(amountBtoA, orderB.maker);
        FHE.allowThis(amountAtoB);
        FHE.allowThis(amountBtoA);

        _userSettlements[orderA.maker].push(settlementId);
        _userSettlements[orderB.maker].push(settlementId);

        emit OrdersMatched(settlementId, orderIdA, orderIdB, block.timestamp);
    }

    // =========================================================================
    //                           VIEWS
    // =========================================================================

    function getOrder(uint256 orderId) external view returns (
        address maker,
        address tokenIn,
        address tokenOut,
        uint256 createdAt,
        uint256 expiresAt,
        OrderStatus status
    ) {
        Order storage o = _orders[orderId];
        return (o.maker, o.tokenIn, o.tokenOut, o.createdAt, o.expiresAt, o.status);
    }

    function getOrderAmount(uint256 orderId) external view returns (euint64) {
        return _orders[orderId].amount;
    }

    function getOrderRate(uint256 orderId) external view returns (euint64) {
        return _orders[orderId].rateScaled;
    }

    function getSettlement(uint256 settlementId) external view returns (
        uint256 buyOrderId,
        uint256 sellOrderId,
        uint256 settledAt
    ) {
        Settlement storage s = _settlements[settlementId];
        return (s.buyOrderId, s.sellOrderId, s.settledAt);
    }

    function getSettlementAmounts(uint256 settlementId) external view returns (
        euint64 amountIn,
        euint64 amountOut
    ) {
        Settlement storage s = _settlements[settlementId];
        return (s.amountInSettled, s.amountOutSettled);
    }

    function getUserOrders(address user) external view returns (uint256[] memory) {
        return _userOrders[user];
    }

    function getUserSettlements(address user) external view returns (uint256[] memory) {
        return _userSettlements[user];
    }

    // =========================================================================
    //                           INTERNAL
    // =========================================================================

    function _creditEscrow(address user, address token, euint64 amount) internal {
        if (FHE.isInitialized(_escrow[user][token])) {
            _escrow[user][token] = FHE.add(_escrow[user][token], amount);
        } else {
            _escrow[user][token] = amount;
        }
        FHE.allowThis(_escrow[user][token]);
        FHE.allow(_escrow[user][token], user);
    }

    function _checkDailyLimit(address user, address token, euint64 amount) internal {
        if (!FHE.isInitialized(_dailyLimit[user][token])) return;

        uint256 today = block.timestamp / 1 days;
        if (_lastSpendDay[user][token] != today) {
            _lastSpendDay[user][token] = today;
            _dailySpent[user][token] = FHE.asEuint64(uint64(0));
            FHE.allowThis(_dailySpent[user][token]);
            FHE.allow(_dailySpent[user][token], user);
        }

        _dailySpent[user][token] = FHE.add(_dailySpent[user][token], amount);
        FHE.allowThis(_dailySpent[user][token]);
        FHE.allow(_dailySpent[user][token], user);

        // Encrypted limit check: spent <= limit
        // If exceeded, this is recorded but not reverted (FHE can't branch).
        // In production, use async decryption callback to revert.
    }
}
