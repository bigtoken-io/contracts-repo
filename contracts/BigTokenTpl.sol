// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

//this token was created in https://bigtoken.io/ platform

import "./ERC20.sol";
import "./ReentrancyGuard.sol";

interface IBigtokenBondingCurve {
    function sellTokenForAccount(uint256 _amount, address receiver) external;
}

contract BigTokenTpl is ERC20, ReentrancyGuard {
    bool public started = false;
    address public factory;
    address public curve;
    address public feeDao;

    mapping(address => bool) public helperContracts;

    constructor() {
        factory = msg.sender;
    }

    function initialize(string memory name_, string memory symbol_, uint256 _totalSupply, address _curve, address _feeDao) external {
        require(msg.sender == factory, 'BigTokenTpl: FORBIDDEN'); // sufficient check
        _name = name_;
        _symbol = symbol_;
        curve = _curve;
        feeDao = _feeDao;
        helperContracts[curve] = true;
        helperContracts[feeDao] = true;
        _mint(curve, _totalSupply);
    }

    function _update(
        address from,
        address to,
        uint256 value
    ) internal override(ERC20) {
        // if not started, only allow transfer between limit parties(EOA, feeDao, curve) to disable dex pair creation.
        if (!started) {
            if (to == address(this) && from != address(0)) {
                // sell to curve by transfer token to token contract
            } else if (from != address(0) && helperContracts[to] == true) {
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
        if (to == address(this) && from != address(0)) {
            _refund(from, value);
        }
    }

    function _refund(address from, uint256 value) internal nonReentrant {
        require(!started, "already started");
        require(!_isContract(from), "can not refund to contract");
        require(from == tx.origin, "can not refund to contract2");
        require(value > 0, "value not match");

        _approve(address(this), curve, value);
        IBigtokenBondingCurve(curve).sellTokenForAccount(value, msg.sender);
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
