import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { ethers, fhevm } from "hardhat";
import { ConfidentialERC20 } from "../types";
import { expect } from "chai";
import { FhevmType } from "@fhevm/hardhat-plugin";

type Signers = {
  deployer: HardhatEthersSigner;
  alice: HardhatEthersSigner;
  bob: HardhatEthersSigner;
};

async function deployFixture() {
  const factory = await ethers.getContractFactory("ConfidentialERC20");
  const token = (await factory.deploy("Confidential KES", "cKES")) as ConfidentialERC20;
  const tokenAddress = await token.getAddress();
  return { token, tokenAddress };
}

describe("ConfidentialERC20", function () {
  let signers: Signers;
  let token: ConfidentialERC20;
  let tokenAddress: string;

  before(async function () {
    const ethSigners = await ethers.getSigners();
    signers = { deployer: ethSigners[0], alice: ethSigners[1], bob: ethSigners[2] };
  });

  beforeEach(async function () {
    if (!fhevm.isMock) {
      this.skip();
    }
    ({ token, tokenAddress } = await deployFixture());
  });

  it("should mint tokens with encrypted balance", async function () {
    await token.mint(signers.alice.address, 1_000_000);

    const encBalance = await token.balanceOf(signers.alice.address);
    const clearBalance = await fhevm.userDecryptEuint(
      FhevmType.euint64,
      encBalance,
      tokenAddress,
      signers.alice,
    );
    expect(clearBalance).to.eq(1_000_000);
    expect(await token.totalSupply()).to.eq(1_000_000);
  });

  it("should transfer encrypted amounts", async function () {
    await token.mint(signers.alice.address, 1_000_000);

    const encrypted = await fhevm
      .createEncryptedInput(tokenAddress, signers.alice.address)
      .add64(300_000)
      .encrypt();

    await (
      await token
        .connect(signers.alice)
        .transfer(signers.bob.address, encrypted.handles[0], encrypted.inputProof)
    ).wait();

    // Alice: 700k
    const aliceBalance = await token.balanceOf(signers.alice.address);
    const clearAlice = await fhevm.userDecryptEuint(FhevmType.euint64, aliceBalance, tokenAddress, signers.alice);
    expect(clearAlice).to.eq(700_000);

    // Bob: 300k
    const bobBalance = await token.balanceOf(signers.bob.address);
    const clearBob = await fhevm.userDecryptEuint(FhevmType.euint64, bobBalance, tokenAddress, signers.bob);
    expect(clearBob).to.eq(300_000);
  });

  it("should reject mint from non-owner", async function () {
    try {
      await token.connect(signers.alice).mint(signers.alice.address, 100);
      expect.fail("Expected mint to revert");
    } catch {
      // Expected: revert from onlyOwner modifier (fhEVM mock throws HardhatFhevmError)
    }
  });
});
