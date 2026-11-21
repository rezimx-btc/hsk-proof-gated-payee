// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Script.sol";
import "../src/ProofGatedPayeeHSK.sol";

/// @notice Deploy ProofGatedPayeeHSK.
/// @dev Usage (HSK Chain testnet, chain ID 133 — verified live via
///      eth_chainId 0x85 on https://testnet.hsk.xyz):
///      export DEPLOYER_PRIVATE_KEY=0x...   # fresh TESTNET-ONLY key, never commit
///      forge script script/Deploy.s.sol:Deploy \
///        --rpc-url https://testnet.hsk.xyz --broadcast --verify \
///        --verifier blockscout \
///        --verifier-url https://testnet-explorer.hskchain.net/api
contract Deploy is Script {
    function run() external returns (ProofGatedPayeeHSK pg) {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(pk);
        pg = new ProofGatedPayeeHSK();
        vm.stopBroadcast();
        console.log("ProofGatedPayeeHSK deployed at:", address(pg));
        console.log("owner:", pg.owner());
    }
}
