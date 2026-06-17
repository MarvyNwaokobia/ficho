import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { ethers, fhevm } from "hardhat";
import { SealedFX, MockERC20 } from "../types";
import { expect } from "chai";
import { FhevmType } from "@fhevm/hardhat-plugin";

type Signers = {
  deployer: HardhatEthersSigner;
  alice: HardhatEthersSigner;
  bob: HardhatEthersSigner;
};

const RATE_SCALE = 1_000_000;
const ONE_HOUR = 3600;

async function deployFixture() {
  const MockERC20Factory = await ethers.getContractFactory("MockERC20");
  const kes = (await MockERC20Factory.deploy("Kenyan Shilling", "KES")) as MockERC20;
  const ngn = (await MockERC20Factory.deploy("Nigerian Naira", "NGN")) as MockERC20;

  const SealedFXFactory = await ethers.getContractFactory("SealedFX");
  const sealedFX = (await SealedFXFactory.deploy()) as SealedFX;

  const sealedFXAddress = await sealedFX.getAddress();
  const kesAddress = await kes.getAddress();
  const ngnAddress = await ngn.getAddress();

  // Enable the KES/NGN pair
  await sealedFX.setSupportedPair(kesAddress, ngnAddress, true);

  return { sealedFX, sealedFXAddress, kes, ngn, kesAddress, ngnAddress };
}

describe("SealedFX", function () {
  let signers: Signers;
  let sealedFX: SealedFX;
  let sealedFXAddress: string;
  let kes: MockERC20;
  let ngn: MockERC20;
  let kesAddress: string;
  let ngnAddress: string;

  before(async function () {
    const ethSigners = await ethers.getSigners();
    signers = { deployer: ethSigners[0], alice: ethSigners[1], bob: ethSigners[2] };
  });

  beforeEach(async function () {
    if (!fhevm.isMock) {
      console.warn("Skipping: tests require mock FHE environment");
      this.skip();
    }
    ({ sealedFX, sealedFXAddress, kes, ngn, kesAddress, ngnAddress } = await deployFixture());
  });

  // =========================================================================
  //  DEPOSITS
  // =========================================================================

  describe("Deposits", function () {
    it("should deposit ERC-20 tokens into encrypted escrow", async function () {
      await kes.mint(signers.alice.address, 1_000_000);
      await kes.connect(signers.alice).approve(sealedFXAddress, 1_000_000);

      await expect(sealedFX.connect(signers.alice).deposit(kesAddress, 500_000))
        .to.emit(sealedFX, "Deposited")
        .withArgs(signers.alice.address, kesAddress, 500_000);

      // ERC-20 balance reduced
      expect(await kes.balanceOf(signers.alice.address)).to.eq(500_000);
      // Contract holds the tokens
      expect(await kes.balanceOf(sealedFXAddress)).to.eq(500_000);
    });

    it("should allow user to decrypt their escrow balance", async function () {
      await kes.mint(signers.alice.address, 1_000_000);
      await kes.connect(signers.alice).approve(sealedFXAddress, 1_000_000);
      await sealedFX.connect(signers.alice).deposit(kesAddress, 750_000);

      const encBalance = await sealedFX.connect(signers.alice).escrowBalance(kesAddress);
      const clearBalance = await fhevm.userDecryptEuint(
        FhevmType.euint64,
        encBalance,
        sealedFXAddress,
        signers.alice,
      );
      expect(clearBalance).to.eq(750_000);
    });

    it("should reject deposit of zero amount", async function () {
      await expect(sealedFX.connect(signers.alice).deposit(kesAddress, 0)).to.be.revertedWithCustomError(
        sealedFX,
        "ZeroAmount",
      );
    });
  });

  // =========================================================================
  //  ORDERS
  // =========================================================================

  describe("Order creation", function () {
    beforeEach(async function () {
      // Fund and deposit for Alice (KES) and Bob (NGN)
      await kes.mint(signers.alice.address, 1_000_000);
      await kes.connect(signers.alice).approve(sealedFXAddress, 1_000_000);
      await sealedFX.connect(signers.alice).deposit(kesAddress, 1_000_000);

      await ngn.mint(signers.bob.address, 1_000_000);
      await ngn.connect(signers.bob).approve(sealedFXAddress, 1_000_000);
      await sealedFX.connect(signers.bob).deposit(ngnAddress, 1_000_000);
    });

    it("should create a sealed order and deduct from escrow", async function () {
      const encrypted = await fhevm
        .createEncryptedInput(sealedFXAddress, signers.alice.address)
        .add64(500_000)
        .add64(130 * RATE_SCALE)
        .encrypt();

      await expect(
        sealedFX
          .connect(signers.alice)
          .createOrder(kesAddress, ngnAddress, encrypted.handles[0], encrypted.handles[1], encrypted.inputProof, ONE_HOUR),
      ).to.emit(sealedFX, "OrderCreated");

      // Escrow should be reduced by 500k
      const encBalance = await sealedFX.connect(signers.alice).escrowBalance(kesAddress);
      const clearBalance = await fhevm.userDecryptEuint(
        FhevmType.euint64,
        encBalance,
        sealedFXAddress,
        signers.alice,
      );
      expect(clearBalance).to.eq(500_000);
    });

    it("should reject order for unsupported pair", async function () {
      const fakeToken = "0x0000000000000000000000000000000000000099";
      const encrypted = await fhevm
        .createEncryptedInput(sealedFXAddress, signers.alice.address)
        .add64(100)
        .add64(100)
        .encrypt();

      await expect(
        sealedFX
          .connect(signers.alice)
          .createOrder(kesAddress, fakeToken, encrypted.handles[0], encrypted.handles[1], encrypted.inputProof, ONE_HOUR),
      ).to.be.revertedWithCustomError(sealedFX, "PairNotSupported");
    });
  });

  // =========================================================================
  //  CANCELLATION
  // =========================================================================

  describe("Order cancellation", function () {
    beforeEach(async function () {
      await kes.mint(signers.alice.address, 1_000_000);
      await kes.connect(signers.alice).approve(sealedFXAddress, 1_000_000);
      await sealedFX.connect(signers.alice).deposit(kesAddress, 1_000_000);
    });

    it("should return escrowed amount on cancel", async function () {
      const encrypted = await fhevm
        .createEncryptedInput(sealedFXAddress, signers.alice.address)
        .add64(600_000)
        .add64(130 * RATE_SCALE)
        .encrypt();

      await (
        await sealedFX
          .connect(signers.alice)
          .createOrder(kesAddress, ngnAddress, encrypted.handles[0], encrypted.handles[1], encrypted.inputProof, ONE_HOUR)
      ).wait();

      // Escrow should be 400k after locking 600k
      let encBalance = await sealedFX.connect(signers.alice).escrowBalance(kesAddress);
      let clearBalance = await fhevm.userDecryptEuint(FhevmType.euint64, encBalance, sealedFXAddress, signers.alice);
      expect(clearBalance).to.eq(400_000);

      // Cancel — should restore to 1M
      await sealedFX.connect(signers.alice).cancelOrder(0);

      encBalance = await sealedFX.connect(signers.alice).escrowBalance(kesAddress);
      clearBalance = await fhevm.userDecryptEuint(FhevmType.euint64, encBalance, sealedFXAddress, signers.alice);
      expect(clearBalance).to.eq(1_000_000);
    });

    it("should reject cancel from non-maker", async function () {
      const encrypted = await fhevm
        .createEncryptedInput(sealedFXAddress, signers.alice.address)
        .add64(100_000)
        .add64(130 * RATE_SCALE)
        .encrypt();

      await (
        await sealedFX
          .connect(signers.alice)
          .createOrder(kesAddress, ngnAddress, encrypted.handles[0], encrypted.handles[1], encrypted.inputProof, ONE_HOUR)
      ).wait();

      await expect(sealedFX.connect(signers.bob).cancelOrder(0)).to.be.revertedWithCustomError(
        sealedFX,
        "NotOrderMaker",
      );
    });
  });

  // =========================================================================
  //  MATCHING & SETTLEMENT
  // =========================================================================

  describe("Matching and settlement", function () {
    beforeEach(async function () {
      // Alice has 1M KES, Bob has 1M NGN
      await kes.mint(signers.alice.address, 1_000_000);
      await kes.connect(signers.alice).approve(sealedFXAddress, 1_000_000);
      await sealedFX.connect(signers.alice).deposit(kesAddress, 1_000_000);

      await ngn.mint(signers.bob.address, 1_000_000);
      await ngn.connect(signers.bob).approve(sealedFXAddress, 1_000_000);
      await sealedFX.connect(signers.bob).deposit(ngnAddress, 1_000_000);
    });

    it("should match orders and settle escrow balances", async function () {
      // Alice: sell 500k KES for NGN at rate 130 (scaled)
      const aliceEnc = await fhevm
        .createEncryptedInput(sealedFXAddress, signers.alice.address)
        .add64(500_000)
        .add64(130 * RATE_SCALE)
        .encrypt();

      await (
        await sealedFX
          .connect(signers.alice)
          .createOrder(kesAddress, ngnAddress, aliceEnc.handles[0], aliceEnc.handles[1], aliceEnc.inputProof, ONE_HOUR)
      ).wait();

      // Bob: sell 500k NGN for KES at rate 8000 (scaled)
      // 130e6 * 8000e6 = 1.04e15 >= 1e12 threshold → compatible
      const bobEnc = await fhevm
        .createEncryptedInput(sealedFXAddress, signers.bob.address)
        .add64(500_000)
        .add64(8000 * RATE_SCALE)
        .encrypt();

      await (
        await sealedFX
          .connect(signers.bob)
          .createOrder(ngnAddress, kesAddress, bobEnc.handles[0], bobEnc.handles[1], bobEnc.inputProof, ONE_HOUR)
      ).wait();

      // Match
      await expect(sealedFX.connect(signers.deployer).matchOrders(0, 1))
        .to.emit(sealedFX, "OrdersMatched");

      // Alice should now have 500k NGN in escrow (received from Bob)
      const aliceNGN = await sealedFX.connect(signers.alice).escrowBalance(ngnAddress);
      const clearAliceNGN = await fhevm.userDecryptEuint(FhevmType.euint64, aliceNGN, sealedFXAddress, signers.alice);
      expect(clearAliceNGN).to.eq(500_000);

      // Bob should now have 500k KES in escrow (received from Alice)
      const bobKES = await sealedFX.connect(signers.bob).escrowBalance(kesAddress);
      const clearBobKES = await fhevm.userDecryptEuint(FhevmType.euint64, bobKES, sealedFXAddress, signers.bob);
      expect(clearBobKES).to.eq(500_000);
    });

    it("should handle partial fills (different amounts)", async function () {
      // Alice: sell 300k KES
      const aliceEnc = await fhevm
        .createEncryptedInput(sealedFXAddress, signers.alice.address)
        .add64(300_000)
        .add64(130 * RATE_SCALE)
        .encrypt();

      await (
        await sealedFX
          .connect(signers.alice)
          .createOrder(kesAddress, ngnAddress, aliceEnc.handles[0], aliceEnc.handles[1], aliceEnc.inputProof, ONE_HOUR)
      ).wait();

      // Bob: sell 500k NGN (larger than Alice's order)
      const bobEnc = await fhevm
        .createEncryptedInput(sealedFXAddress, signers.bob.address)
        .add64(500_000)
        .add64(8000 * RATE_SCALE)
        .encrypt();

      await (
        await sealedFX
          .connect(signers.bob)
          .createOrder(ngnAddress, kesAddress, bobEnc.handles[0], bobEnc.handles[1], bobEnc.inputProof, ONE_HOUR)
      ).wait();

      await (await sealedFX.connect(signers.deployer).matchOrders(0, 1)).wait();

      // Settled on min(300k, 500k) = 300k
      // Alice gets 300k NGN
      const aliceNGN = await sealedFX.connect(signers.alice).escrowBalance(ngnAddress);
      const clearAliceNGN = await fhevm.userDecryptEuint(FhevmType.euint64, aliceNGN, sealedFXAddress, signers.alice);
      expect(clearAliceNGN).to.eq(300_000);

      // Bob gets 300k KES
      const bobKES = await sealedFX.connect(signers.bob).escrowBalance(kesAddress);
      const clearBobKES = await fhevm.userDecryptEuint(FhevmType.euint64, bobKES, sealedFXAddress, signers.bob);
      expect(clearBobKES).to.eq(300_000);

      // Bob's NGN escrow: 500k remaining (1M - 500k locked) + 200k excess returned = 700k
      const bobNGN = await sealedFX.connect(signers.bob).escrowBalance(ngnAddress);
      const clearBobNGN = await fhevm.userDecryptEuint(FhevmType.euint64, bobNGN, sealedFXAddress, signers.bob);
      expect(clearBobNGN).to.eq(700_000);
    });

    it("should reject matching with wrong token pairs", async function () {
      // Both sell KES (same direction — can't match)
      const enc1 = await fhevm
        .createEncryptedInput(sealedFXAddress, signers.alice.address)
        .add64(100_000)
        .add64(130 * RATE_SCALE)
        .encrypt();

      await (
        await sealedFX
          .connect(signers.alice)
          .createOrder(kesAddress, ngnAddress, enc1.handles[0], enc1.handles[1], enc1.inputProof, ONE_HOUR)
      ).wait();

      const enc2 = await fhevm
        .createEncryptedInput(sealedFXAddress, signers.bob.address)
        .add64(100_000)
        .add64(130 * RATE_SCALE)
        .encrypt();

      // Bob also deposits KES
      await kes.mint(signers.bob.address, 1_000_000);
      await kes.connect(signers.bob).approve(sealedFXAddress, 1_000_000);
      await sealedFX.connect(signers.bob).deposit(kesAddress, 1_000_000);

      await (
        await sealedFX
          .connect(signers.bob)
          .createOrder(kesAddress, ngnAddress, enc2.handles[0], enc2.handles[1], enc2.inputProof, ONE_HOUR)
      ).wait();

      await expect(sealedFX.connect(signers.deployer).matchOrders(0, 1)).to.be.revertedWithCustomError(
        sealedFX,
        "TokenPairMismatch",
      );
    });
  });

  // =========================================================================
  //  DAILY LIMITS
  // =========================================================================

  describe("Daily limits", function () {
    beforeEach(async function () {
      await kes.mint(signers.alice.address, 1_000_000);
      await kes.connect(signers.alice).approve(sealedFXAddress, 1_000_000);
      await sealedFX.connect(signers.alice).deposit(kesAddress, 1_000_000);
    });

    it("should set and read encrypted daily limit", async function () {
      const encLimit = await fhevm
        .createEncryptedInput(sealedFXAddress, signers.alice.address)
        .add64(200_000)
        .encrypt();

      await (
        await sealedFX.connect(signers.alice).setDailyLimit(kesAddress, encLimit.handles[0], encLimit.inputProof)
      ).wait();

      const encDailyLimit = await sealedFX.connect(signers.alice).getDailyLimit(kesAddress);
      const clearLimit = await fhevm.userDecryptEuint(
        FhevmType.euint64,
        encDailyLimit,
        sealedFXAddress,
        signers.alice,
      );
      expect(clearLimit).to.eq(200_000);
    });
  });
});
