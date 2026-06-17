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
3. The FHE contract checks compatibility — `TFHE.le(alice.rate, bob.rate)` — without decrypting
4. If matched, settlement flows in confidential stablecoins (ERC-7984)
5. Each party decrypts only their own settlement confirmation via EIP-712

The blockchain computed on numbers it never saw.

## Why FHE

| Alternative | Why it fails here |
|---|---|
| ZK proofs | Can verify, but can't compute matching on hidden inputs |
| Trusted hardware (SGX) | Centralized trust assumption |
| Commit-reveal | Amounts revealed at reveal phase — still front-runnable |
| FHE | Computes on encrypted data. Matching runs without decryption. |

## Tech stack

- **Contracts**: Solidity 0.8.24, Zama fhEVM (TFHE library)
- **Network**: Ethereum Sepolia (fhEVM devnet)
- **Frontend**: Next.js, fhevmjs
- **Token standard**: ERC-7984 (confidential ERC-20)

## Development

```bash
# Install dependencies
pnpm install

# Compile contracts
npx hardhat compile

# Run tests
npx hardhat test

# Deploy to Sepolia
npx hardhat run scripts/deploy.ts --network sepolia
```

## License

MIT
