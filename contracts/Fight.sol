// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/draft-ERC20Permit.sol";

contract Fight is ERC20, ERC20Permit {
    constructor() ERC20("Fight to MAGA", "FIGHT") ERC20Permit("Fight to MAGA") {
        _mint(msg.sender, 1000000000 * 10 ** decimals());
    }
}
