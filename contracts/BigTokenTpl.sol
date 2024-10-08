// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

//this token was created in https://bigtoken.io/ platform

import "./ERC20.sol";
import "./ReentrancyGuard.sol";

contract BigTokenTpl is ERC20, ReentrancyGuard {
    bool public started = false;
    address public factory;
    address public curve;
    address public feeDao;
    bool public isInitialized;
    address public owner = address(0x0);   //to shutup go+ security warning.
    mapping(address => bool) public helperContracts;

    constructor() {
        factory = msg.sender;
    }

    function initialize(string memory name_, string memory symbol_, uint256 totalSupply_, address _curve, address _feeDao) external {
        require(msg.sender == factory, 'BigTokenTpl: FORBIDDEN'); // sufficient check
        require(!isInitialized, "already inited");

      	isInitialized = true;
        _name = name_;
        _symbol = symbol_;
        curve = _curve;
        feeDao = _feeDao;
        helperContracts[curve] = true;
        helperContracts[feeDao] = true;
        _mint(curve, totalSupply_);
    }

    function _update(
        address from,
        address to,
        uint256 value
    ) internal override(ERC20) {
        // if not started, only allow transfer between limit parties(EOA, feeDao, curve) to disable dex pair creation.
        if (!started) {
            if (from != address(0) && helperContracts[to] == true) {
                //sell to curve or limit transfer
            } else {
                // else, check and revert.
                if (from != address(0) && from != address(this) && helperContracts[from] == false) {
                    revert("all tokens are in limit transfer status until launch.");
                }
            }
        } else {
            if (to == address(this) && from != address(0)) {
                revert(
                    "You can not send token to contract after launched."
                );
            }
        }
        super._update(from, to, value);
    }

    function setStarted() external {
        require(msg.sender == curve, "forbidden");
        started = true;
    }

    function _isContract(address _addr) internal view returns (bool) {
        uint32 size;
        assembly {
            size := extcodesize(_addr)
        }
        return (size > 0);
    }
}
