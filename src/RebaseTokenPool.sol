// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Pool} from "@ccip/chains/evm/contracts/libraries/Pool.sol";
import {TokenPool} from "@ccip/chains/evm/contracts/pools/TokenPool.sol";
import {IERC20} from "@chainlink-local/lib/chainlink-evm/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/interfaces/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IRebaseToken} from "./interfaces/IRebaseToken.sol";

contract RebaseTokenPool is TokenPool {
    
    constructor (
        IERC20 token, 
        uint8 localTokenDecimal, 
        address[] memory allowlist, 
        address rmnProxy, 
        address router
    ) TokenPool(token, localTokenDecimal, allowlist, rmnProxy, router) {}

    // This function will be called by the CCIP Router
    function lockOrBurn(Pool.LockOrBurnInV1 calldata lockOrBurnIn)
        external    // only CCIP Router can call this
        virtual     // Future contracts can override this function
        override    // This replaces the parent function
        returns(Pool.LockOrBurnOutV1 memory lockOrBurnOut)
    {
        // this is a security function inherited from TokenPool
        // it performs various checks on the incoming cross-chain request
        // ensures only authorized CCIP contracts (like OnRamp) can call this function
        // Checks if msg.sender is in the allowlist of permitted callers
        _validateLockOrBurn(lockOrBurnIn);

        // get the user interest rate from the original sender
        uint256 userInterestRate = IRebaseToken(address(i_token)).getUserInterestRate(lockOrBurnIn.originalSender);
        
        // burn the tokens from the pool
        IRebaseToken(address(i_token)).burn(address(this), lockOrBurnIn.amount);

        // prepare teh output structure
        lockOrBurnOut = Pool.LockOrBurnOutV1({
            // the address of the token contract on the destination chain
            // getRemoteToken looks up the token address for the target chain
            // tells CCIP where to mint/release tokens on the destination chain
            destTokenAddress: getRemoteToken(lockOrBurnIn.remoteChainSelector),

            // encode data to send to the destination chain's pool
            // user's interest packed into bytes
            // preserve the user's interest rate across chains
            // so the destination pool can mint tokens with the correct state
            destPoolData: abi.encode(userInterestRate)
        });
    } 

    // release or mint function
    function releaseOrMint(Pool.ReleaseOrMintInV1 calldata releaseOrMintIn)
        external
        returns (Pool.ReleaseOrMintOutV1 memory)
    {
        _validateReleaseOrMint(releaseOrMintIn);
        address receiver = releaseOrMintIn.receiver;
        (uint256 userInterestRate) = abi.decode(releaseOrMintIn.sourcePoolData, (uint256));
        IRebaseToken(address(i_token)).mint(receiver, releaseOrMintIn.amount, userInterestRate);

        return Pool.ReleaseOrMintOutV1({
            destinationAmount: releaseOrMintIn.amount
        });
    }
}