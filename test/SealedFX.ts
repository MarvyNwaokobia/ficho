import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { ethers, fhevm } from "hardhat";
import { SealedFX, SealedFX__factory } from "../types";
import { expect } from "chai";
import { FhevmType } from "@fhevm/hardhat-plugin";

type Signers = {
  deployer: HardhatEthersSigner;
  alice: HardhatEthersSigner;
  bob: HardhatEthersSigner;
};

const TOKEN_KES = "0x0000000000000000000000000000000000000001";
const TOKEN_NGN = "0x0000000000000000000000000000000000000002";
const RATE_SCALE = 1_000_000;
const ONE_HOUR = 3600;

async function deployFixture() {
  const factory = (await ethers.getContractFactory("SealedFX")) as SealedFX__factory;
  const contract = (await factory.deploy()) as SealedFX;
  const contractAddress = await contract.getAddress();
  return { contract, contractAddress };
}

describe("SealedFX", function () {
  let signers: Signers;
  let contract: SealedFX;
  let contractAddress: string;

  before(async function () {
    const ethSigners = await ethers.getSigners();
    signers = { deployer: ethSigners[0], alice: ethSigners[1], bob: ethSigners[2] };
  });

  beforeEach(async function () {
    if (!fhevm.isMock) {
      console.warn("Skipping: tests require mock FHE environment");
      this.skip();
    }
    ({ contract, contractAddress } = await deployFixture());
  });

  describe("Order creation", function () {
    it("should create an order with encrypted amount and rate", async function () {
      const amount = 500_000;
      const rate = 130 * RATE_SCALE;

      const encrypted = await fhevm
        .createEncryptedInput(contractAddress, signers.alice.address)
        .add64(amount)
        .add64(rate)
        .encrypt();

      const tx = await contract
        .connect(signers.alice)
        .createOrder(TOKEN_KES, TOKEN_NGN, encrypted.handles[0], encrypted.handles[1], encrypted.inputProof, ONE_HOUR);
      await tx.wait();

      expect(await contract.nextOrderId()).to.eq(1);

      const userOrders = await contract.getUserOrders(signers.alice.address);
      expect(userOrders.length).to.eq(1);
      expect(userOrders[0]).to.eq(0);
    });

    it("should allow maker to decrypt their own order amount", async function () {
      const amount = 250_000;
      const rate = 130 * RATE_SCALE;

      const encrypted = await fhevm
        .createEncryptedInput(contractAddress, signers.alice.address)
        .add64(amount)
        .add64(rate)
        .encrypt();

      const tx = await contract
        .connect(signers.alice)
        .createOrder(TOKEN_KES, TOKEN_NGN, encrypted.handles[0], encrypted.handles[1], encrypted.inputProof, ONE_HOUR);
      await tx.wait();

      const encryptedAmount = await contract.getOrderAmount(0);
      const decryptedAmount = await fhevm.userDecryptEuint(
        FhevmType.euint64,
        encryptedAmount,
        contractAddress,
        signers.alice,
      );
      expect(decryptedAmount).to.eq(amount);
    });
  });

  describe("Order cancellation", function () {
    it("should allow maker to cancel their order", async function () {
      const encrypted = await fhevm
        .createEncryptedInput(contractAddress, signers.alice.address)
        .add64(100_000)
        .add64(130 * RATE_SCALE)
        .encrypt();

      await (
        await contract
          .connect(signers.alice)
          .createOrder(TOKEN_KES, TOKEN_NGN, encrypted.handles[0], encrypted.handles[1], encrypted.inputProof, ONE_HOUR)
      ).wait();

      await expect(contract.connect(signers.alice).cancelOrder(0)).to.emit(contract, "OrderCancelled").withArgs(0);
    });

    it("should reject cancellation from non-maker", async function () {
      const encrypted = await fhevm
        .createEncryptedInput(contractAddress, signers.alice.address)
        .add64(100_000)
        .add64(130 * RATE_SCALE)
        .encrypt();

      await (
        await contract
          .connect(signers.alice)
          .createOrder(TOKEN_KES, TOKEN_NGN, encrypted.handles[0], encrypted.handles[1], encrypted.inputProof, ONE_HOUR)
      ).wait();

      await expect(contract.connect(signers.bob).cancelOrder(0)).to.be.revertedWithCustomError(
        contract,
        "NotOrderMaker",
      );
    });
  });

  describe("Order matching", function () {
    it("should match two compatible orders", async function () {
      // Alice: sell 500k KES for NGN at rate 130 (1 KES = 130 NGN units, scaled)
      const aliceEncrypted = await fhevm
        .createEncryptedInput(contractAddress, signers.alice.address)
        .add64(500_000)
        .add64(130 * RATE_SCALE)
        .encrypt();

      await (
        await contract
          .connect(signers.alice)
          .createOrder(
            TOKEN_KES,
            TOKEN_NGN,
            aliceEncrypted.handles[0],
            aliceEncrypted.handles[1],
            aliceEncrypted.inputProof,
            ONE_HOUR,
          )
      ).wait();

      // Bob: sell 500k NGN for KES at rate 8000 (1 NGN = 0.008 KES, scaled)
      // Rate product: 130e6 * 8000e6 = 1.04e15 >= 1e12 → compatible
      const bobEncrypted = await fhevm
        .createEncryptedInput(contractAddress, signers.bob.address)
        .add64(500_000)
        .add64(8000 * RATE_SCALE)
        .encrypt();

      await (
        await contract
          .connect(signers.bob)
          .createOrder(
            TOKEN_NGN,
            TOKEN_KES,
            bobEncrypted.handles[0],
            bobEncrypted.handles[1],
            bobEncrypted.inputProof,
            ONE_HOUR,
          )
      ).wait();

      // Match orders
      const tx = await contract.connect(signers.deployer).matchOrders(0, 1);
      await tx.wait();

      expect(await contract.nextMatchId()).to.eq(1);
    });
  });
});
