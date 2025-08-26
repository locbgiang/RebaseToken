// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Pool} from "@ccip/chains/evm/contracts/libraries/Pool.sol";
import {TokenPool} from "@ccip/chains/evm/contracts/pools/TokenPool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IRebaseToken} from "./interfaces/IRebaseToken.sol";

contract RebaseTokenPool is TokenPool {
    // constructor to initialize the tokenpool
    // lock or burn function
    // release or mint function
}