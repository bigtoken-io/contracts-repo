// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./BigtokenBondingCurve.sol";
import "./access/Governable.sol";
import "./ReentrancyGuard.sol";
import "./IERC20.sol";
import "./SafeERC20.sol";

contract BigtokenHelper is Governable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Address for address payable;

    uint256 public _tokenDeployedCount;
    mapping(uint256 => address) public _tokensDeployed;
    mapping(address => BigtokenBondingCurve) public tokenAddrToBondingCurve;
    mapping(bytes32 => address) public deployedSymbols;
    mapping(address => bool) public curves;
    mapping(address => bool) public tokenAddrToSeedFlag;

    address public feeDao;
    address public uniswapRouter;
    address public uniswapFactory;
    uint256 public platformFeePercent = 20;	// 20/1000 = 2%

    uint256 public percentMaxReservedForMining = 100;	// 10/1000 = 10%
    uint256 public baseTotalSupply = 1000000000 * 10**18;

    mapping (address => bool) public isKeeper;

    event TokenDeployed(uint256 id, address indexed token, address curve, address deployedBy, uint256 deployTime);
    event SetKeeper(address indexed account, bool isActive);
    event Transaction(address indexed tokenAddr, address indexed trader, uint256 amountToken, uint256 amountETH, uint256 price, uint256 supply, string buyOrSell, int256 slippage);
    event BondedEvent(address indexed tokenAddr, uint256 amountETH, uint256 timestamp);
    event LaunchEvent(address indexed tokenAddr, address curve, address pair_address, uint256 amount, uint256 ethAmount, uint256 liquidity, uint256 platformFee);

    constructor(address _feeDao, address _uniswapRouter, address _uniswapFactory) {
        feeDao = _feeDao;
        uniswapRouter = _uniswapRouter;
        uniswapFactory = _uniswapFactory;

        deployedSymbols[keccak256(abi.encodePacked("BIGTOKEN"))] = address(0x1);
        deployedSymbols[keccak256(abi.encodePacked("bigtoken"))] = address(0x1);
        deployedSymbols[keccak256(abi.encodePacked("BIG"))] = address(0x1);
        deployedSymbols[keccak256(abi.encodePacked("big"))] = address(0x1);
    }

    function deployToken(string memory _name, string memory _symbol, uint256 _percentReservedForMining) external payable nonReentrant returns (address) {
        bytes32 symbolEncoded = keccak256(abi.encodePacked(_symbol));
        require(deployedSymbols[symbolEncoded] == address(0x0), "symbol already deployed");
        require(_percentReservedForMining <= percentMaxReservedForMining, "token reserved for mining too large!");

        uint256 id = _tokenDeployedCount++;

        uint256 _totalSupply = calcTotalSupply(_percentReservedForMining);

        BigtokenBondingCurve curve = new BigtokenBondingCurve(address(this), uniswapRouter, uniswapFactory);
        address tokenAddress = curve.initialize(_name, _symbol, _totalSupply, _percentReservedForMining);
        tokenAddrToBondingCurve[tokenAddress] = curve;
        _tokensDeployed[id] = tokenAddress;
        deployedSymbols[symbolEncoded] = tokenAddress;
        curves[address(curve)] = true;

        if (msg.value > 0) {
            curve.buyTokenForAccount{value: msg.value}(msg.sender);
        }

        //console.log("tokenAddress: ", tokenAddress);
        emit TokenDeployed(id, tokenAddress, address(curve), msg.sender, block.timestamp);
        return tokenAddress;
    }

    function calcTotalSupply(uint256 _percentReservedForMining) public view returns (uint256) {
        if (_percentReservedForMining > 0) {
            return baseTotalSupply + baseTotalSupply * _percentReservedForMining / 1000;
        }
        return baseTotalSupply;
    }

    function createDexPool(address tokenAddr) external onlyKeeper {
        require(tokenAddrToSeedFlag[tokenAddr] == false, "already seed");
        tokenAddrToBondingCurve[tokenAddr].startDexTrade();
        tokenAddrToSeedFlag[tokenAddr] = true;
    }

    function setUnbond(address tokenAddr) external onlyKeeper {
        tokenAddrToBondingCurve[tokenAddr].setUnbond();
    }

    function emitTradeEvent(address tokenAddr, address trader, uint256 amountToken, uint256 amountETH, uint256 price, 
                          uint256 bondedAmount, string memory buyOrSell, int256 slippage) external onlyCurve {
        emit Transaction(tokenAddr, trader, amountToken, amountETH, price, bondedAmount, buyOrSell, slippage);
    }

    function emitBondedEvent(address tokenAddr, uint256 amountETH) external onlyCurve {
        emit BondedEvent(tokenAddr, amountETH, block.timestamp);
    }

    function emitLaunchEvent(address tokenAddr, address curve, address pairAddress, uint256 tokenAmount, uint256 ethAmount, uint256 liquidity, uint256 platformFee) external onlyCurve {
        emit LaunchEvent(tokenAddr, curve, pairAddress, tokenAmount, ethAmount, liquidity, platformFee);
    }

    modifier onlyCurve() {
        require(curves[msg.sender], "forbidden");
        _;
    }

    modifier onlyKeeper() {
        require(isKeeper[msg.sender], "forbidden");
        _;
    }

    function setKeeper(address _account, bool _isActive) external onlyGov {
        isKeeper[_account] = _isActive;
        emit SetKeeper(_account, _isActive);
    }

    function setFeeDao(address _dao) external onlyGov {
        require(_dao != address(0x0), "invalid");
        feeDao = _dao;
    }

    function setUniswapRouter(address _uniswapRouter) external onlyGov {
        require(_uniswapRouter != address(0x0), "invalid");
        uniswapRouter = _uniswapRouter;
    }

    function setUniswapFactory(address _uniswapFactory) external onlyGov {
        require(_uniswapFactory != address(0x0), "invalid");
        uniswapFactory = _uniswapFactory;
    }

    function setPlatformFeePercent(uint256 _platformFeePercent) external onlyGov {
        platformFeePercent = _platformFeePercent;
    }

    function setPercentMaxReservedForMining(uint256 _percentMaxReservedForMining) external onlyGov {
        percentMaxReservedForMining = _percentMaxReservedForMining;
    }

    function tokenDeployedCount() external view returns (uint256) {
        return _tokenDeployedCount;
    }

    receive() external payable {
    }

    // to help users who accidentally send their tokens to this contract
    function withdrawETH(address payable _receiver) external onlyGov nonReentrant {
        uint256 balance = address(this).balance;
        _receiver.sendValue(balance);
    }

    // to help users who accidentally send their tokens to this contract
    function withdrawToken(address _token, address _account, uint256 _amount) external onlyGov nonReentrant {
        IERC20(_token).safeTransfer(_account, _amount);
    }
}
