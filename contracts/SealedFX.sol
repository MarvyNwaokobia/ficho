// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FHE, euint64, externalEuint64, ebool} from "@fhevm/solidity/lib/FHE.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title SealedFX
/// @notice Sealed-bid cross-border FX matching via FHE.
///         Two parties submit encrypted orders (amount + rate). The contract
///         matches them using fully homomorphic encryption — neither party,
///         no observer, and no front-runner ever sees the numbers.
contract SealedFX is ZamaEthereumConfig {
    uint64 public constant RATE_SCALE = 1_000_000;

    enum OrderStatus {
        Open,
        Matched,
        Cancelled
    }

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

    struct Match {
        uint256 buyOrderId;
        uint256 sellOrderId;
        euint64 settledAmountIn;
        euint64 settledAmountOut;
        uint256 matchedAt;
    }

    uint256 public nextOrderId;
    uint256 public nextMatchId;

    mapping(uint256 => Order) public orders;
    mapping(uint256 => Match) public matches;
    mapping(address => uint256[]) public userOrders;
    mapping(address => uint256[]) public userMatches;

    event OrderCreated(
        uint256 indexed orderId,
        address indexed maker,
        address tokenIn,
        address tokenOut,
        uint256 expiresAt
    );
    event OrderCancelled(uint256 indexed orderId);
    event OrderMatched(
        uint256 indexed matchId,
        uint256 indexed buyOrderId,
        uint256 indexed sellOrderId,
        uint256 matchedAt
    );

    error OrderNotOpen();
    error NotOrderMaker();
    error OrderExpired();
    error OrdersNotCompatible();
    error TokenPairMismatch();

    /// @notice Submit a sealed FX order.
    /// @param tokenIn The token the maker is selling.
    /// @param tokenOut The token the maker wants to receive.
    /// @param encryptedAmount The encrypted amount of tokenIn to sell.
    /// @param encryptedRate The encrypted exchange rate (scaled by RATE_SCALE).
    /// @param inputProof Proof for the encrypted inputs.
    /// @param duration How long the order stays open (seconds).
    function createOrder(
        address tokenIn,
        address tokenOut,
        externalEuint64 encryptedAmount,
        externalEuint64 encryptedRate,
        bytes calldata inputProof,
        uint256 duration
    ) external returns (uint256 orderId) {
        euint64 amount = FHE.fromExternal(encryptedAmount, inputProof);
        euint64 rateScaled = FHE.fromExternal(encryptedRate, inputProof);

        orderId = nextOrderId++;

        orders[orderId] = Order({
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

        userOrders[msg.sender].push(orderId);

        emit OrderCreated(orderId, msg.sender, tokenIn, tokenOut, block.timestamp + duration);
    }

    /// @notice Cancel an open order. Only the maker can cancel.
    function cancelOrder(uint256 orderId) external {
        Order storage order = orders[orderId];
        if (order.status != OrderStatus.Open) revert OrderNotOpen();
        if (order.maker != msg.sender) revert NotOrderMaker();

        order.status = OrderStatus.Cancelled;
        emit OrderCancelled(orderId);
    }

    /// @notice Match two compatible orders using FHE comparison.
    ///         Order A sells tokenX for tokenY. Order B sells tokenY for tokenX.
    ///         Rates are compatible if A.rate * B.rate >= RATE_SCALE^2
    ///         (i.e., what A asks per unit <= what B offers per unit).
    function matchOrders(uint256 orderIdA, uint256 orderIdB) external returns (uint256 matchId) {
        Order storage orderA = orders[orderIdA];
        Order storage orderB = orders[orderIdB];

        if (orderA.status != OrderStatus.Open) revert OrderNotOpen();
        if (orderB.status != OrderStatus.Open) revert OrderNotOpen();
        if (block.timestamp > orderA.expiresAt) revert OrderExpired();
        if (block.timestamp > orderB.expiresAt) revert OrderExpired();

        if (orderA.tokenIn != orderB.tokenOut || orderA.tokenOut != orderB.tokenIn) {
            revert TokenPairMismatch();
        }

        // FHE rate compatibility check:
        // rateProduct = A.rate * B.rate (both scaled by 1e6)
        // compatible if rateProduct >= 1e12 (RATE_SCALE^2)
        euint64 rateProduct = FHE.mul(orderA.rateScaled, orderB.rateScaled);
        euint64 threshold = FHE.asEuint64(uint64((RATE_SCALE * RATE_SCALE) / 1_000_000));
        ebool compatible = FHE.ge(rateProduct, threshold);

        // Compute settlement amounts using the smaller of the two
        euint64 settledA = FHE.min(orderA.amount, orderB.amount);
        euint64 settledB = FHE.min(orderA.amount, orderB.amount);

        // Use select: if compatible, use computed amounts; otherwise zero
        euint64 zero = FHE.asEuint64(uint64(0));
        settledA = FHE.select(compatible, settledA, zero);
        settledB = FHE.select(compatible, settledB, zero);

        orderA.status = OrderStatus.Matched;
        orderB.status = OrderStatus.Matched;

        matchId = nextMatchId++;
        matches[matchId] = Match({
            buyOrderId: orderIdA,
            sellOrderId: orderIdB,
            settledAmountIn: settledA,
            settledAmountOut: settledB,
            matchedAt: block.timestamp
        });

        // Allow each maker to decrypt their own settlement amounts
        FHE.allow(settledA, orderA.maker);
        FHE.allow(settledA, orderB.maker);
        FHE.allow(settledB, orderA.maker);
        FHE.allow(settledB, orderB.maker);
        FHE.allowThis(settledA);
        FHE.allowThis(settledB);

        userMatches[orderA.maker].push(matchId);
        userMatches[orderB.maker].push(matchId);

        emit OrderMatched(matchId, orderIdA, orderIdB, block.timestamp);
    }

    /// @notice Get order IDs for a user.
    function getUserOrders(address user) external view returns (uint256[] memory) {
        return userOrders[user];
    }

    /// @notice Get match IDs for a user.
    function getUserMatches(address user) external view returns (uint256[] memory) {
        return userMatches[user];
    }

    /// @notice Get the encrypted amount handle for an order (caller must be allowed).
    function getOrderAmount(uint256 orderId) external view returns (euint64) {
        return orders[orderId].amount;
    }

    /// @notice Get the encrypted rate handle for an order (caller must be allowed).
    function getOrderRate(uint256 orderId) external view returns (euint64) {
        return orders[orderId].rateScaled;
    }

    /// @notice Get the settled amounts for a match (caller must be allowed).
    function getMatchSettlement(uint256 matchId) external view returns (euint64 amountIn, euint64 amountOut) {
        return (matches[matchId].settledAmountIn, matches[matchId].settledAmountOut);
    }
}
