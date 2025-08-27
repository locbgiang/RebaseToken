// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Pool} from "@ccip/chains/evm/contracts/libraries/Pool.sol";
import {TokenPool} from "@ccip/chains/evm/contracts/pools/TokenPool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IRebaseToken} from "./interfaces/IRebaseToken.sol";

contract RebaseTokenPool is TokenPool {
    
    constructor (
        IERC20 token, 
        uint8 localTokenDecimal, 
        address[] memory allowlist, 
        address rmnProxy, 
        address router
    ) TokenPool(token, 8, allowlist, rmnProxy, router) {}

    // This function will be called by the CCIP Router
    function lockOrBurn(Pool.LockOrBurnInV1 calldata lockOrBurnIn)
        external    // only CCIP Router can call this
        virtual     // Future contracts can override this function
        override    // This replaces the parent function
        returns(Pool.LockOrBurnOutV1 memory lockOrBurnOut)
    {
        // validate the input paremeters
        _validateLockOrBurn(lockOrBurnIn);

        // get the user interest rate from the original sender
        uint256 userInterestRate = IRebaseToken(address(i_token)).getUserInterestRate(lockOrBurnIn.originalSender);
        
        // 
        IRebaseToken(address(i_token)).burn(address(this), lockOrBurnIn.amount);

        lockOrBurnOut = Pool.LockOrBurnOutV1({
            destTokenAddress: getRemoteToken(lockOrBurnIn.remoteChainSelector),
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