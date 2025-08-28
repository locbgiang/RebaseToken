// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {console, Test} from "forge-std/Test.sol";

// forge install smartcontractkit/chainlink-local@v0.2.5-beta.0
import {CCIPLocalSimulatorFork, Register} from "@chainlink-local/src/ccip/CCIPLocalSimulatorFork.sol";
import {TokenPool} from "@ccip/chains/evm/contracts/pools/TokenPool.sol";
import {RegistryModuleOwnerCustom} from "@ccip/chains/evm/contracts/tokenAdminRegistry/RegistryModuleOwnerCustom.sol";
import {TokenAdminRegistry} from "@ccip/chains/evm/contracts/tokenAdminRegistry/TokenAdminRegistry.sol";
import {RateLimiter} from "@ccip/chains/evm/contracts/libraries/RateLimiter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IRouterClient} from "@ccip/chains/evm/contracts/interfaces/IRouterClient.sol";
import {Client} from "@ccip/chains/evm/contracts/libraries/Client.sol";

import {RebaseToken} from "../src/RebaseToken.sol";
import {RebaseTokenPool} from "../src/RebaseTokenPool.sol";
import {Vault} from "./RebaseToken.t.sol";
import {IRebaseToken} from "../src/interfaces/IRebaseToken.sol";

contract CrossChainTest is Test {
    // create deterministic test addresses for different roles
    // owner deploys contracts, alice performs cross-chain transfers
    address public owner = makeAddr("owner");
    address alice = makeAddr("alice");

    // simulates CCIP infrastructure locally for testing
    CCIPLocalSimulatorFork public ccipLocalSimulatorFork;

    // amount of tokens to transfer in tests
    uint256 public SEND_VALUE = 1e5;

    // Fork management:
    // track different blockchain forks for multi-chain testing
    // switching between chains with vm.selectFork(sepoliaFork);
    uint256 sepoliaFork;
    uint256 arbSepoliaFork;

    // Token contracts:
    // separate token instances for each chain
    // tokens burned on source, minted on destination
    RebaseToken destRebaseToken;
    RebaseToken sourceRebaseToken;

    // Pool contracts:
    // handles cross-chain token burn/mints
    // flows: sourcePool.lockOrBurn -> CCIP -> destPool.releaseOrMint
    RebaseTokenPool destPool;
    RebaseTokenPool sourcePool;

    // Token Admin Registries:
    // register tokens with CCIP infrastructure
    // for CCIP to recognize the token as transferable
    TokenAdminRegistry tokenAdminRegistrySepolia;
    TokenAdminRegistry tokenAdminRegistryArbSepolia;

    // Network details:
    // store chain-specific CCIP configuration
    // contains: router addresses, chain selectors, RMN proxies
    Register.NetworkDetails sepoliaNetworkDetails;
    Register.NetworkDetails arbSepoliaNetworkDetails;

    // Registry Modules:
    // Custom ownership modules for token registration
    // control who can modify token pool configurations
    RegistryModuleOwnerCustom registryModuleOwnerCustomSepolia;
    RegistryModuleOwnerCustom registryModuleOwnerCustomArbSepolia;

    // 
    Vault vault;

    /**
     * This setup creates a complete cross-chain environment where:
     * 1. Sepolia acts as the source chain with a rebase token pool, and vault
     * 2. arbitrum acts as the destination chain with matching contracts
     * 3. both chains are properly registered with ccip for cross-chain token transfer
     * 4. the vault can provide rebase rewards on the source chain
     */
    function setUp() public {
        // 1. initial setup
        // creates an empty allowlist for token pools
        address[] memory allowlist = new address[](1);

        // setup the two blockchain forks:
        // ethereum sepolia and arbitrum sepolia
        // createSelectFork makes sepolia the active fork
        sepoliaFork = vm.createSelectFork("eth");
        arbSepoliaFork = vm.createFork("arb");

        // note: what does this do?
        // creates a local CCIP simulator for cross-chain testing
        // vm.makePersistent ensure the simulator persists accross fork switches
        ccipLocalSimulatorFork = new CCIPLocalSimulatorFork();
        vm.makePersistent(address(ccipLocalSimulatorFork));

        // source chain sepolia deployment
        // get network configuration details for the current chain 
        // (sepolia because we used createSelectFork)
        sepoliaNetworkDetails = ccipLocalSimulatorFork.getNetworkDetails(block.chainid);

        // start exectuing transactions as the owner address
        vm.startPrank(owner);

        // owner deploy core contracts
        // deploy rebase token contract on sepolia
        // calls it sourceRebaseToken because it is on the source chain
        sourceRebaseToken = new RebaseToken();
        console.log("Source rebase token address: ");
        console.log(address(sourceRebaseToken));
        console.log("Deploying token pool on Sepolia: ");

        // now that we have the token
        // the allowlist
        // and the network details
        // deploy a token pool for ccip integration
        sourcePool = new RebaseTokenPool(
            IERC20(address(sourceRebaseToken)),
            8,
            allowlist,
            sepoliaNetworkDetails.rmnProxyAddress,
            sepoliaNetworkDetails.routerAddress
        );

        // deploy a vault contract and funds it with 1 ETH
        vault = new Vault(IRebaseToken(address(sourceRebaseToken)));
        vm.deal(address(vault), 1e18);

        // with the sourcePool and vault deployed 
        // we have to grant them permission:
        // allows the pool and vault to mint/burn tokens
        sourceRebaseToken.grantMintAndBurnRole(address(sourcePool));
        sourceRebaseToken.grantMintAndBurnRole(address(vault));

        // register with ccip admin registry:
        // registers the token with ccip admin system
        registryModuleOwnerCustomSepolia = RegistryModuleOwnerCustom(
            sepoliaNetworkDetails.registryModuleOwnerCustomAddress
        );
        registryModuleOwnerCustomSepolia.registerAdminViaOwner(
            address(sourceRebaseToken)
        );
    }
}