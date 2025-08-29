// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {console, Test} from "forge-std/Test.sol";

// forge install smartcontractkit/chainlink-local@v0.2.5-beta.0
import {CCIPLocalSimulatorFork, Register} from "@chainlink-local/src/ccip/CCIPLocalSimulatorFork.sol";
import {TokenPool} from "@ccip/chains/evm/contracts/pools/TokenPool.sol";
import {RegistryModuleOwnerCustom} from "@ccip/chains/evm/contracts/tokenAdminRegistry/RegistryModuleOwnerCustom.sol";
import {TokenAdminRegistry} from "@ccip/chains/evm/contracts/tokenAdminRegistry/TokenAdminRegistry.sol";
import {RateLimiter} from "@ccip/chains/evm/contracts/libraries/RateLimiter.sol";
import {IERC20} from "@chainlink-local/lib/chainlink-evm/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/interfaces/IERC20.sol";
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

    // Network details:
    // store chain-specific CCIP configuration
    // contains: router addresses, chain selectors, RMN proxies
    Register.NetworkDetails sepoliaNetworkDetails;
    Register.NetworkDetails arbSepoliaNetworkDetails;

    // Registry Modules:
    // Custom ownership modules for token registration
    // control who can modify token pool configurations
    // (the bouncer, validates who can enter)
    RegistryModuleOwnerCustom registryModuleOwnerCustomSepolia;
    RegistryModuleOwnerCustom registryModuleOwnerCustomArbSepolia;

    // Token Admin Registries:
    // register tokens with CCIP infrastructure
    // for CCIP to recognize the token as transferable
    // (the manager, manages what members can do)
    TokenAdminRegistry tokenAdminRegistrySepolia;
    TokenAdminRegistry tokenAdminRegistryArbSepolia;

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
        console.log("Deploying RebaseToken on Sepolia...");
        sourceRebaseToken = new RebaseToken();
        console.log("Source rebase token address: ");
        console.log(address(sourceRebaseToken));

        // now that we have the token
        // the allowlist
        // and the network details
        // deploy a token pool for ccip integration
        console.log("Deploying token pool on Sepolia...");
        sourcePool = new RebaseTokenPool(
            IERC20(address(sourceRebaseToken)),
            8,
            allowlist,
            sepoliaNetworkDetails.rmnProxyAddress,
            sepoliaNetworkDetails.routerAddress
        );

        // deploy a vault contract and funds it with 1 ETH
        console.log("Deploying vault on Sepolia...");
        vault = new Vault(IRebaseToken(address(sourceRebaseToken)));
        vm.deal(address(vault), 1e18);

        // with the sourcePool and vault deployed 
        // we have to grant them permission:
        // allows the pool and vault to mint/burn tokens
        sourceRebaseToken.grantMintAndBurnRole(address(sourcePool));
        sourceRebaseToken.grantMintAndBurnRole(address(vault));

        // registering the rebase token with CCIP administrative system
        // get the reference to CCIP's pre-deployed registry module on sepolia
        registryModuleOwnerCustomSepolia = RegistryModuleOwnerCustom(
            // this is the actual address of the contract on sepolia
            sepoliaNetworkDetails.registryModuleOwnerCustomAddress
        );
        // registers RebaseToken in CCIP's system
        // Propose the caller (owner) as the admin for this token
        // creates a pending admin role
        registryModuleOwnerCustomSepolia.registerAdminViaOwner(
            address(sourceRebaseToken) // register this token
        ); 

        // accept the admin role for the token
        // get reference to CCIP's pre-deployed token admin registry on sepolia
        tokenAdminRegistrySepolia = TokenAdminRegistry(
            // this is the actual address of the contract on sepolia
            sepoliaNetworkDetails.tokenAdminRegistryAddress
        );
        // from that reference, accept the admin role for our token
        tokenAdminRegistrySepolia.acceptAdminRole(
            address(sourceRebaseToken) // owner accepts being admin for this token
        );

        // links the token to it's pool
        tokenAdminRegistrySepolia.setPool(
            address(sourceRebaseToken),
            address(sourcePool)
        );

        vm.stopPrank();

        // destination chain arbitrum deployment
        // switch to arbitrum fork
        vm.selectFork(arbSepoliaFork);

        // get network configuration details for the current chain
        // (arbSepolia because we switched forks)
        arbSepoliaNetworkDetails = ccipLocalSimulatorFork.getNetworkDetails(block.chainid);
        
        vm.startPrank(owner);

        // deploy the destination RebaseToken contract on arbitrum
        // calls it destRebaseToken because it is on the destination chain
        console.log("Deploying RebaseToken on Arbitrum...");
        destRebaseToken = new RebaseToken();

        console.log("Destination RebaseToken address: ");
        console.log(address(destRebaseToken));

        // deploy the destination RebaseTokenPool on arbitrum
        console.log("Deploying token pool on Arbitrum...");
        destPool = new RebaseTokenPool(
            IERC20(address(destRebaseToken)),
            8,
            allowlist,
            arbSepoliaNetworkDetails.rmnProxyAddress,
            arbSepoliaNetworkDetails.routerAddress
        );

        // deploying vault on arbitrum
        console.log("Deploying vault on Arbitrum...");
        Vault arbVault = new Vault(IRebaseToken(address(destRebaseToken)));
        vm.deal(address(arbVault), 1e18);  // Fund with ETH

        // grant mint/burn role to the destination pool and vault
        destRebaseToken.grantMintAndBurnRole(address(destPool));
        destRebaseToken.grantMintAndBurnRole(address(arbVault));

        // registering the rebase token with CCIP administrative system
        // get the reference to CCIP's pre-deployed registry module on arbitrum
        registryModuleOwnerCustomArbSepolia = RegistryModuleOwnerCustom(
            // this is the actual address of the contract on arbitrum
            arbSepoliaNetworkDetails.registryModuleOwnerCustomAddress
        );
        // registers RebaseToken in CCIP's system on arbitrum
        // propose the caller (owner) as the admin for this token
        registryModuleOwnerCustomArbSepolia.registerAdminViaOwner(
            address(destRebaseToken) // register this token
        );

        // accept the admin role for the token on arbitrum
        // get reference to CCIP's pre-deployed token admin registry on arbitrum
        tokenAdminRegistryArbSepolia = TokenAdminRegistry(
            // this is the actual address of the contract on arbitrum
            arbSepoliaNetworkDetails.tokenAdminRegistryAddress
        );
        // from that reference, accept the admin role for our token
        tokenAdminRegistryArbSepolia.acceptAdminRole(
            address(destRebaseToken) // owner accepts being admin for this token
        );

        // links the token and it's pool on arbitrum
        tokenAdminRegistryArbSepolia.setPool(
            address(destRebaseToken),
            address(destPool)
        );

        vm.stopPrank();
    }

    function configureTokenPool(
        uint256 fork,
        TokenPool localPool,
        TokenPool remotePool,
        IRebaseToken token,
        Register.NetworkDetails memory remoteNetworkDetails
    ) public {
        vm.selectFork(fork);
        vm.startPrank(owner);
        TokenPool.ChainUpdate[] memory chains = new TokenPool.ChainUpdate[](1);
        bytes[] memory remotePoolAddresses = new bytes[](1);
        remotePoolAddresses[0] = abi.encode(address(remotePool));
        chains[0] = TokenPool.ChainUpdate({
            remoteChainSelector: remoteNetworkDetails.chainSelector,
            remotePoolAddresses: remotePoolAddresses,
            remoteTokenAddress: abi.encode(address(token)),
            outboundRateLimiterConfig: RateLimiter.Config({
                isEnabled: false,
                capacity: 0,
                rate: 0
            }),
            inboundRateLimiterConfig: RateLimiter.Config({
                isEnabled: false,
                capacity: 0,
                rate: 0
            })
        });
        uint64[] memory remoteChainSelectorsToRemove = new uint64[](0);
        localPool.applyChainUpdates(remoteChainSelectorsToRemove, chains);
        vm.stopPrank();
    }
}