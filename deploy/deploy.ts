import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();
  const { deploy, execute } = hre.deployments;

  // Deploy mock ERC-20 tokens (testnet faucet)
  const kes = await deploy("MockERC20_KES", {
    contract: "MockERC20",
    from: deployer,
    args: ["Kenyan Shilling", "KES"],
    log: true,
  });

  const ngn = await deploy("MockERC20_NGN", {
    contract: "MockERC20",
    from: deployer,
    args: ["Nigerian Naira", "NGN"],
    log: true,
  });

  const usdt = await deploy("MockERC20_USDT", {
    contract: "MockERC20",
    from: deployer,
    args: ["Tether USD", "USDT"],
    log: true,
  });

  // Deploy ConfidentialERC20 showcase tokens
  const cKES = await deploy("ConfidentialERC20_cKES", {
    contract: "ConfidentialERC20",
    from: deployer,
    args: ["Confidential KES", "cKES"],
    log: true,
  });

  const cNGN = await deploy("ConfidentialERC20_cNGN", {
    contract: "ConfidentialERC20",
    from: deployer,
    args: ["Confidential NGN", "cNGN"],
    log: true,
  });

  // Deploy SealedFX
  const sealedFX = await deploy("SealedFX", {
    from: deployer,
    log: true,
  });

  // Configure supported pairs
  await execute("SealedFX", { from: deployer, log: true }, "setSupportedPair", kes.address, ngn.address, true);
  await execute("SealedFX", { from: deployer, log: true }, "setSupportedPair", kes.address, usdt.address, true);
  await execute("SealedFX", { from: deployer, log: true }, "setSupportedPair", ngn.address, usdt.address, true);

  console.log("\n=== Ficho Deployment ===");
  console.log(`SealedFX:     ${sealedFX.address}`);
  console.log(`KES:          ${kes.address}`);
  console.log(`NGN:          ${ngn.address}`);
  console.log(`USDT:         ${usdt.address}`);
  console.log(`cKES:         ${cKES.address}`);
  console.log(`cNGN:         ${cNGN.address}`);
  console.log("========================\n");
};

export default func;
func.id = "deploy_ficho";
func.tags = ["Ficho"];
