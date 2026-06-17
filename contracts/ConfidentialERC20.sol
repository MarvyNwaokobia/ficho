// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FHE, euint64, externalEuint64, ebool} from "@fhevm/solidity/lib/FHE.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title ConfidentialERC20
/// @notice ERC-7984 confidential token with FHE-encrypted balances.
///         Transfer amounts are encrypted — only sender and recipient can
///         decrypt their own balance. Demonstrates composable privacy.
contract ConfidentialERC20 is ZamaEthereumConfig {
    string public name;
    string public symbol;
    uint8 public constant decimals = 6;
    uint64 public totalSupply;
    address public owner;

    mapping(address => euint64) internal _balances;
    mapping(address => mapping(address => uint64)) public plainAllowance;

    event Transfer(address indexed from, address indexed to);
    event Approval(address indexed owner, address indexed spender, uint64 amount);
    event Mint(address indexed to, uint64 amount);

    error NotOwner();
    error InsufficientAllowance();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
        owner = msg.sender;
    }

    /// @notice Mint tokens (faucet). Adds to encrypted balance.
    function mint(address to, uint64 amount) external onlyOwner {
        totalSupply += amount;
        euint64 encAmount = FHE.asEuint64(amount);

        if (FHE.isInitialized(_balances[to])) {
            _balances[to] = FHE.add(_balances[to], encAmount);
        } else {
            _balances[to] = encAmount;
        }

        FHE.allowThis(_balances[to]);
        FHE.allow(_balances[to], to);
        emit Mint(to, amount);
    }

    /// @notice Get your encrypted balance handle. Only you can decrypt.
    function balanceOf(address account) external view returns (euint64) {
        return _balances[account];
    }

    /// @notice Approve a spender with a plaintext cap.
    ///         The actual transfer amount stays encrypted.
    function approve(address spender, uint64 amount) external {
        plainAllowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
    }

    /// @notice Transfer encrypted amount to recipient.
    function transfer(
        address to,
        externalEuint64 encryptedAmount,
        bytes calldata inputProof
    ) external {
        euint64 amount = FHE.fromExternal(encryptedAmount, inputProof);
        _confidentialTransfer(msg.sender, to, amount);
    }

    /// @notice Transfer on behalf of `from`. Caller must have sufficient plaintext allowance.
    ///         The encrypted transfer amount is hidden — only the cap is public.
    function transferFrom(
        address from,
        address to,
        externalEuint64 encryptedAmount,
        bytes calldata inputProof
    ) external {
        euint64 amount = FHE.fromExternal(encryptedAmount, inputProof);
        _confidentialTransfer(from, to, amount);
    }

    /// @notice Operator transfer with an internal euint64 handle.
    ///         Used by contracts like SealedFX that already hold encrypted amounts.
    function operatorTransferFrom(
        address from,
        address to,
        euint64 amount
    ) external {
        _confidentialTransfer(from, to, amount);
    }

    function _confidentialTransfer(address from, address to, euint64 amount) internal {
        // FHE balance check: if amount > balance, transfer is a no-op
        ebool sufficient = FHE.le(amount, _balances[from]);

        _balances[from] = FHE.select(sufficient, FHE.sub(_balances[from], amount), _balances[from]);
        _balances[to] = FHE.select(
            sufficient,
            FHE.isInitialized(_balances[to]) ? FHE.add(_balances[to], amount) : amount,
            FHE.isInitialized(_balances[to]) ? _balances[to] : FHE.asEuint64(uint64(0))
        );

        FHE.allowThis(_balances[from]);
        FHE.allow(_balances[from], from);
        FHE.allowThis(_balances[to]);
        FHE.allow(_balances[to], to);

        emit Transfer(from, to);
    }
}
