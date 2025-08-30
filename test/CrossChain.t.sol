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
        address[] memory allowlist = new address[](0);

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
            18,
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
            18,
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

    /**
     * This function configures cross-chain relationships between two token pools:
     * Pool A learns about pool B (and vice versa)
     * cross-chain mappings established
     * transfer routes configured
     * rate limits set
     */
    function configureTokenPool(
        uint256 fork,
        TokenPool localPool,
        TokenPool remotePool,
        IRebaseToken token,
        Register.NetworkDetails memory remoteNetworkDetails
    ) public {
        // this is the chain we are opperating on
        vm.selectFork(fork); 

        // set msg.sender to owner for permission check
        vm.startPrank(owner);

        // creates an array to hold chain configuration updates
        // size of 1 because we're configuring one remote chain relationship
        TokenPool.ChainUpdate[] memory chains = new TokenPool.ChainUpdate[](1);

        // creates an array to store remote pool addresses
        bytes[] memory remotePoolAddresses = new bytes[](1);

        // abi.encode(address(remotePool)): converts pool address to bytes format
        // why bytes? ccip uses bytes to support different address formats across chains
        remotePoolAddresses[0] = abi.encode(address(remotePool));

        // chain updates configuration
        chains[0] = TokenPool.ChainUpdate({
            // remoteChainSelector: Unique ID for destination chain (e.g Arbitrum)
            remoteChainSelector: remoteNetworkDetails.chainSelector,  
            // remotePoolAddresses: Which pool(s) handle tokens on remote chain
            remotePoolAddresses: remotePoolAddresses,
            // remoteTokenAddress: Which token contract exists on remote chain          
            remoteTokenAddress: abi.encode(address(token)),    
            // outboundRateLimiterConfig: Limits for tokens leaving this chain
            outboundRateLimiterConfig: RateLimiter.Config({    
                isEnabled: false,       // no rate limiting
                capacity: 0,            // max tokens in bucket
                rate: 0                 // refill rate per second
            }),
            // inboundRateLimiterConfig: Limits for tokens arriving from remote chain
            inboundRateLimiterConfig: RateLimiter.Config({      
                isEnabled: false,       // no rate limiting
                capacity: 0,            // max tokens in bucket
                rate: 0                 // refill rate per second
            })
        });
        // empty array because we're not removing any existing chain configuration
        // size 0 means 'dont remove any chains'
        uint64[] memory remoteChainSelectorsToRemove = new uint64[](0);
        localPool.applyChainUpdates(remoteChainSelectorsToRemove, chains);
        vm.stopPrank();
    }


    /**
     * This function simulates cross-chain token transfer using CCIP
     */
    function bridgeToken(
        uint256 amountToBridge,
        uint256 localFork,
        uint256 remoteFork,
        Register.NetworkDetails memory localNetworkDetails,
        Register.NetworkDetails memory remoteNetworkDetails,
        RebaseToken localToken,
        RebaseToken remoteToken
    ) public {
        // switch to the source blockchain where tokens will be sent from
        vm.selectFork(localFork);
        // makes all subsequent transaction as the owner address
        vm.startPrank(alice);

        // Client is a library from chainlink CCIP that contains data structures/utilities
        // for cross-chain messaging, token transfers, ect.
        // EVMTokenAmount is a struct representing a token and it's amount

        // tokenToSendDetails: creates an array to specify which token and amount to bridge
        // this tells CCIP "send X amount of Y token"
        Client.EVMTokenAmount[] memory tokenToSendDetails = new Client.EVMTokenAmount[](1);
        // create the struct
        Client.EVMTokenAmount memory tokenAmount = Client.EVMTokenAmount({
            token: address(localToken),
            amount: amountToBridge
        });
        // add that struct to the array
        tokenToSendDetails[0] = tokenAmount;

        // approve the data
        // approves the router to burn tokens on users behalf
        IERC20(address(localToken)).approve(
            localNetworkDetails.routerAddress,
            amountToBridge
        );

        // CCIP message creation:
        // creates the cross-chain message containing all transfer details
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(alice),
            data: "",
            tokenAmounts: tokenToSendDetails,
            extraArgs: "",
            feeToken: localNetworkDetails.linkAddress
        });

        // Fee handling:
        // Fee preparation: gets LINK token for alice to pay CCIP fees
        // Calculates the exact fee needed for this message
        vm.stopPrank();
        ccipLocalSimulatorFork.requestLinkFromFaucet(
            alice, IRouterClient(localNetworkDetails.routerAddress).getFee(remoteNetworkDetails.chainSelector, message)
        );

        // Fee approval:
        // Alice approves the router to spend her LINK tokens for fees
        vm.startPrank(alice);
        IERC20(localNetworkDetails.linkAddress).approve(
            localNetworkDetails.routerAddress,
            IRouterClient(localNetworkDetails.routerAddress).getFee(remoteNetworkDetails.chainSelector, message)
        );

        // Pre-bridge Balance:
        // Records Alice token balance before briding
        uint256 balanceBeforeBridge = IERC20(address(localToken)).balanceOf(alice);
        console.log("Local balance before bridge: %d", balanceBeforeBridge);

        // Execute the transfer
        // what is IRouterClient?
        // localNetworkDetails.routerAddress?
        // remoteNetworkDetails.chainSelector?
        // why?
        IRouterClient(localNetworkDetails.routerAddress).ccipSend(
            remoteNetworkDetails.chainSelector,
            message
        );

        // save the balance after bridging
        uint256 sourceBalanceAfterBridge = IERC20(address(localToken)).balanceOf(alice);
        console.log("Local balance after bridge: %d", sourceBalanceAfterBridge);

        // assert that balance after bridge is = to balance before bridge - amount to bridge
        assertEq(
            sourceBalanceAfterBridge,
            balanceBeforeBridge - amountToBridge
        );

        vm.stopPrank();

        // switch to the destination chain where the tokens will be received
        vm.selectFork(remoteFork);

        // fast forward time by 15 minutes (900 seconds)
        // simulates realistic cross-chain transfer delays and allow time-based mechanics like interest to process
        vm.warp(block.timestamp + 900);

        // record initial balance
        // capture alice's token balance on destination chain before the transfer completes
        uint256 initialArbBalance = IERC20(address(remoteToken)).balanceOf(alice);
        console.log("Remote balance before bridge %d", initialArbBalance);

        // switch back to the source chain
        // the ccip simulator needs to be on the source chain to initiate message routing
        vm.selectFork(localFork);

        // this is the key line
        // simulates ccip cross-chain message delivery
        ccipLocalSimulatorFork.switchChainAndRouteMessage(remoteFork);

        // verify the results
        // checks alice interest rate on the destination chain
        vm.selectFork(remoteFork);
        console.log("Remote user interest rate: %d", remoteToken.getUserInterestRate(alice));

        // the balance on destination chain after the transfer
        uint256 destBalance = IERC20(address(remoteToken)).balanceOf(alice);
        console.log("Remote balance after bridge %d", destBalance);

        // assert that the destination balance = initial balance + amount bridged
        assertEq(destBalance, initialArbBalance + amountToBridge);
    }

    /**
     * This modifier ensures that the token pools are configured
     */
    modifier withConfiguredPools() {
        // sepolia pool knows about arbitrum pool
        configureTokenPool(
            sepoliaFork,
            sourcePool,
            destPool,
            IRebaseToken(address(destRebaseToken)),
            arbSepoliaNetworkDetails
        );
        // arbitrum pool knows about sepolia pool
        configureTokenPool(
            arbSepoliaFork,
            destPool,
            sourcePool,
            IRebaseToken(address(destRebaseToken)),
            arbSepoliaNetworkDetails
        );
        _;
    }

    /**
     * This test function demonstrates a complete cross-chain token bridging workflow
     */
    function testBridgeAllTokens() public withConfiguredPools {
        // token acquisition phase, alice gets token to bridge

        // switch sepolia(source chain)
        vm.selectFork(sepoliaFork);
        // gives alice ETH (SEND_VALUE = 100,000 wei) 
        vm.deal(alice, SEND_VALUE);
        // Alice deposits ETH into vault
        vm.startPrank(alice);
        Vault(payable(address(vault))).deposit{value: SEND_VALUE}();
        console.log("Bridging %d tokens", SEND_VALUE);

        // Verification phase
        // confirms alice has the expected tokens before bridging
        uint256 startBalance = IERC20(address(sourceRebaseToken)).balanceOf(alice);
        assertEq(startBalance, SEND_VALUE);

        // bridge execution phase
        // executes the cross-chain transfer
        // sends CCIP message to Arbitrum
        vm.stopPrank();
        bridgeToken(
            SEND_VALUE,
            sepoliaFork,
            arbSepoliaFork,
            sepoliaNetworkDetails,
            arbSepoliaNetworkDetails,
            sourceRebaseToken,
            destRebaseToken
        );

        // no assertion here because assertions are already one in bridgeToken()
    }

    function testBridgeAllTokenBack() public withConfiguredPools{
        vm.selectFork(sepoliaFork);
        vm.deal(alice, SEND_VALUE);
        vm.startPrank(alice);
        Vault(payable(address(vault))).deposit{value: SEND_VALUE}();
        console.log("Bridging %d tokens", SEND_VALUE);
        uint256 startBalance = IERC20(address(sourceRebaseToken)).balanceOf(alice);
        assertEq(startBalance, SEND_VALUE);
        vm.stopPrank();
        bridgeToken(
            SEND_VALUE,
            sepoliaFork,
            arbSepoliaFork,
            sepoliaNetworkDetails,
            arbSepoliaNetworkDetails,
            sourceRebaseToken,
            destRebaseToken
        );
        vm.selectFork(arbSepoliaFork);
        console.log("User Balance Before Warp: %d", destRebaseToken.balanceOf(alice));
        vm.warp(block.timestamp + 3600); // 1 hour
        console.log("User Balance After Warp: %d", destRebaseToken.balanceOf(alice));
        uint256 destBalance = IERC20(address(destRebaseToken)).balanceOf(alice);
        console.log("Amount bridging back %d tokens", destBalance);
        bridgeToken(
            destBalance,
            arbSepoliaFork,
            sepoliaFork,
            arbSepoliaNetworkDetails,
            sepoliaNetworkDetails,
            destRebaseToken,
            sourceRebaseToken
        );
    }
}