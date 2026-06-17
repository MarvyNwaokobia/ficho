import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();
  const { deploy } = hre.deployments;

  const deployed = await deploy("SealedFX", {
    from: deployer,
    log: true,
  });

  console.log(`SealedFX deployed to: ${deployed.address}`);
};

export default func;
func.id = "deploy_sealedFX";
func.tags = ["SealedFX"];
