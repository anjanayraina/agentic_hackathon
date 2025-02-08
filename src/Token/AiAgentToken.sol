// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "openzeppelin-contracts/token/ERC20/ERC20.sol";

/**
 * @title AIAgentToken
 * @notice A minimal ERC20 token used for staking in AIBattleProtocol.
 */
contract AIAgentToken is ERC20 {
    constructor() ERC20("AIAgentToken", "AIA") {
        // Mint 1,000,000 tokens (with 18 decimals) to the deployer.
        _mint(msg.sender, 1_000_000 * 10 ** decimals());
    }
}
