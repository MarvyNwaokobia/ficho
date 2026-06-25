# Ficho

Sealed-bid cross-border FX matching, powered by FHE.

> *Ficho* — Swahili for "hidden place."

Two parties submit encrypted FX orders. The contract matches them using fully homomorphic encryption. Neither party, no observer, and no front-runner ever sees the amounts.

Built for [Zama Developer Program — Season 3](https://www.zama.org/post/zama-developer-program-mainnet-season-3-composable-privacy-is-the-key).

---

## The problem

Cross-border P2P FX (Africa, LatAm, South Asia) on transparent blockchains exposes:
- **Payment amounts** — competitors and MEV bots see everything
- **FX demand signals** — large orders get front-run before settlement
- **Transaction patterns** — full financial surveillance on a public ledger

## The solution

Ficho is a sealed-bid FX matching protocol on Zama's fhEVM:

1. Alice (Kenya) submits an encrypted order: `encrypt(amount_KES, rate)`
2. Bob (Nigeria) submits an encrypted counter-order: `encrypt(amount_NGN, rate)`
3. The FHE contract checks compatibility — `FHE.ge(rateA * rateB, threshold)` — without decrypting
4. If matched, settlement transfers encrypted escrow balances between counterparties
5. Each party decrypts only their own settlement confirmation via EIP-712

The blockchain computed on numbers it never saw.

## Deployed contracts (Sepolia)

| Contract | Address |
|---|---|
| **SealedFX** | [`0x454568f7Fd9bcbD456958C52Fa54A7b8F0384Cf4`](https://sepolia.etherscan.io/address/0x454568f7Fd9bcbD456958C52Fa54A7b8F0384Cf4) |
| KES (MockERC20) | [`0xA08Bc6EDd1A09500Dea6bc810A8fCE24a458B617`](https://sepolia.etherscan.io/address/0xA08Bc6EDd1A09500Dea6bc810A8fCE24a458B617) |
| NGN (MockERC20) | [`0x5f121712C0dBE853b9B079BE25100e0604AA7AcF`](https://sepolia.etherscan.io/address/0x5f121712C0dBE853b9B079BE25100e0604AA7AcF) |
| USDT (MockERC20) | [`0xe61b662C0e2C0855A9d14E8fF2BF1f5065F072A7`](https://sepolia.etherscan.io/address/0xe61b662C0e2C0855A9d14E8fF2BF1f5065F072A7) |
| cKES (ConfidentialERC20) | [`0x7333215204c5E37a98BB79a63715593618c0958c`](https://sepolia.etherscan.io/address/0x7333215204c5E37a98BB79a63715593618c0958c) |
| cNGN (ConfidentialERC20) | [`0x407cD7DD99A10697bA680AB101C86Ca7729D2f74`](https://sepolia.etherscan.io/address/0x407cD7DD99A10697bA680AB101C86Ca7729D2f74) |

Supported pairs: KES/NGN, KES/USDT, NGN/USDT

## Why FHE

| Alternative | Why it fails here |
|---|---|
| ZK proofs | Can verify, but can't compute matching on hidden inputs |
| Trusted hardware (SGX) | Centralized trust assumption |
| Commit-reveal | Amounts revealed at reveal phase — still front-runnable |
| FHE | Computes on encrypted data. Matching runs without decryption. |

## FHE primitives used

| Primitive | Purpose |
|---|---|
| `FHE.mul(rateA, rateB)` | Encrypted rate compatibility check |
| `FHE.ge(product, threshold)` | Sealed comparison — never decrypted |
| `FHE.min(amountA, amountB)` | Settlement amount on partial fills |
| `FHE.select(compatible, x, zero)` | Conditional execution without branching |
| `FHE.add` / `FHE.sub` | Encrypted escrow accounting |
| `FHE.allow(value, address)` | Per-user decrypt permission (EIP-712) |

## Architecture

```
┌─────────────────────────────────────────────────┐
│                   Frontend                       │
│  fhevmjs: encrypt amounts in browser             │
│  EIP-712: decrypt your own balances/settlements  │
└──────────────────────┬──────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────┐
│                  SealedFX                        │
│  deposit(ERC-20) → encrypted escrow              │
│  createOrder(encrypted amount, encrypted rate)   │
│  matchOrders(FHE comparison + settlement)        │
│  withdraw(escrow → ERC-20)                       │
└──────────────────────┬──────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────┐
│            Zama fhEVM Coprocessor                │
│  TFHE operations on encrypted data               │
│  Threshold decryption via KMS                    │
└─────────────────────────────────────────────────┘
```

## Tech stack

- **Contracts**: Solidity 0.8.27, Zama fhEVM (`@fhevm/solidity`)
- **Network**: Ethereum Sepolia (Zama coprocessor)
- **Testing**: Hardhat + `@fhevm/hardhat-plugin` (mock FHE)
- **Frontend**: Next.js, fhevmjs
- **Token standard**: ERC-7984 (confidential ERC-20)

## Development

```bash
# Install dependencies
npm install

# Compile contracts
npx hardhat compile

# Run tests (14 passing)
npx hardhat test

# Deploy to Sepolia
npx hardhat deploy --network sepolia
```

### Environment variables

Copy `.env.example` to `.env` and fill in:

```
PRIVATE_KEY=0x...
ALCHEMY_API_KEY=...
ETHERSCAN_API_KEY=...     # optional, for verification
```

## License

MIT
