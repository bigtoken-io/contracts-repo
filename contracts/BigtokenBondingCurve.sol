// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "./ReentrancyGuard.sol";
import "./BigTokenTpl.sol";
import "./SafeERC20.sol";

interface IUniswapV2Router01 {
    function WETH() external pure returns (address);

    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    )
        external
        payable
        returns (uint amountToken, uint amountETH, uint liquidity);
}

interface IUniswapV2Factory {
    function getPair(
        address tokenA,
        address tokenB
    ) external view returns (address pair);
    function createPair(
        address tokenA,
        address tokenB
    ) external returns (address pair);
}

interface IWETH {
    function deposit() external payable;
    function transfer(address to, uint value) external returns (bool);
}

interface IBigtokenHelper {
  function emitTradeEvent(address tokenAddr, address trader, uint256 amountToken, uint256 amountETH, uint256 price, uint256 bondedAmount, string memory buyOrSell, int256 slippage, uint256 ethReserve, uint256 tokenReserve) external;
  function emitBondedEvent(address tokenAddr, uint256 amountETH) external;
  function emitLaunchEvent(address tokenAddr, address curve, address pairAddress, uint256 tokenAmount, uint256 ethAmount, uint256 liquidity, uint256 platformFee) external;
  function feeDao() external view returns (address);
  function platformFeePercent() external view returns (uint256);
}

contract BigtokenBondingCurve is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;
    
    BigTokenTpl public tmToken;
    address public pairAddr;
    uint256 public ethBalance = 0;
    uint256 public bondedAmount = 0;
    uint256 public totalEthTax = 0;
    uint256 public priceBondCurve = 0;

    bool public isBonded = false;
    bool public isInitialized;
    address public bigtokenHelper;
    address public uniswapRouter;
    address public uniswapFactory;
    address weth;
    uint256 public platformFeePercent;

    uint8 public decimals = 18;
    uint256 public ethReserve = 1.1 ether;
    uint256 public tokenReserve = SafeMath.mul(1073000191, 10**decimals);
    uint256 public maxBondedAmount = SafeMath.mul(787240200, 10**decimals);
    uint256 public baseTotalSupply = 1000000000 * 10**18;

    constructor(address _bigtokenHelper, address _uniswapRouter, address _uniswapFactory) {
        bigtokenHelper = _bigtokenHelper;
        uniswapRouter = _uniswapRouter;
        uniswapFactory = _uniswapFactory;
        platformFeePercent = IBigtokenHelper(bigtokenHelper).platformFeePercent();
        weth = IUniswapV2Router01(uniswapRouter).WETH();
    }

    function initialize(address _tmTokenAddr, uint256 _ethReserve, uint256 _totalSupply, uint256 _percentReservedForMining) external onlyHelper {
        require(!isInitialized, "already inited");
      	isInitialized = true;
    
        tmToken = BigTokenTpl(_tmTokenAddr);
        ethReserve = _ethReserve;
        if (_percentReservedForMining > 0) {
            //transfer reserve part(used for mining reward) to dao
            address feeDao = getFeeDao(); 
            tmToken.transfer(feeDao, _totalSupply - baseTotalSupply);
        }

        address tokenAddr = address(tmToken);
        pairAddr = IUniswapV2Factory(uniswapFactory).getPair(tokenAddr, weth);
        if (pairAddr == address(0)) {
            pairAddr = IUniswapV2Factory(uniswapFactory).createPair(tokenAddr, weth);
        }
        pairAddr = IUniswapV2Factory(uniswapFactory).getPair(tokenAddr, weth);
        // assert pair exists
        assert(pairAddr != address(0));
    }

    // eth(decimal 18) per token
    function getBondPrice() public view returns (uint256) {
        return ethReserve * 10**18 / tokenReserve;
    }

    function calcTokenOutputAmount(uint256 ethAmount) public view returns (uint256 amountOut, uint256 outEthTax) {
        require(ethAmount > 0, 'INSUFFICIENT_INPUT_AMOUNT1');
        require(ethReserve > 0 && tokenReserve > 0, 'INSUFFICIENT_LIQUIDITY2');

        uint256 amountInWithFee = ethAmount.mul(990);
        uint256 numerator = amountInWithFee.mul(tokenReserve);
        uint256 denominator = ethReserve.mul(1000).add(amountInWithFee);
        amountOut = numerator / denominator;
        outEthTax = ethAmount.mul(10).div(1000);
    }

    function calcEthQuoteToBuy(uint256 tokenAmount) public view returns (uint256 usedEth, uint256 outEthTax) {
        require(tokenAmount > 0, 'INSUFFICIENT_INPUT_AMOUNT3');
        require(ethReserve > 0 && tokenReserve > 0, 'INSUFFICIENT_LIQUIDITY4');

        uint256 numerator = ethReserve.mul(tokenAmount);
        uint256 denominator = tokenReserve.sub(tokenAmount);
        uint256 ethVal = numerator / denominator;
        usedEth = ethVal.mul(1000).div(990);
        outEthTax = usedEth.sub(ethVal);
    }

    function calcEthQuoteToSell(uint256 tokenAmount) public view returns (uint256 outEth, uint256 outEthTax) {
        require(tokenAmount > 0, 'INSUFFICIENT_INPUT_AMOUNT5');
        require(ethReserve > 0 && tokenReserve > 0, 'INSUFFICIENT_LIQUIDITY5');

        uint256 numerator = ethReserve.mul(tokenAmount);
        uint256 denominator = tokenReserve.add(tokenAmount);
        uint256 ethVal = numerator / denominator;
        outEth = ethVal.mul(990).div(1000);
        outEthTax = ethVal.sub(outEth);
    }

    /// @param estOutputAmount estimate output amount of Token
    /// @param allowSlip amount of slippage allowed in 100 means 1%
    function buyToken(uint256 estOutputAmount, uint256 allowSlip) external payable nonReentrant {
        _doBuyToken(estOutputAmount, allowSlip, msg.sender);
    }

    function buyTokenForAccount(address receiver) external payable onlyHelper nonReentrant {
        _doBuyToken(0, 0, receiver);
    }

    function _doBuyToken(uint256 estOutputAmount, uint256 allowSlip, address receiver) internal {
        require(!isBonded, "The curve already bonded");
        require(isInitialized, "curve not init");
        require(msg.value > 0, "Amount ETH sent should > 0");
        require(bondedAmount < maxBondedAmount, "curve bonded");

        uint256 outEthTaxG;
        (uint256 outputAmount, uint256 outEthTax1) = calcTokenOutputAmount(msg.value);
        uint256 ethToRefund = 0;
        if (outputAmount > maxBondedAmount.sub(bondedAmount)) {
            //last buy skip slippage check
            outputAmount = maxBondedAmount.sub(bondedAmount);
            (uint256 usedEth, uint256 outEthTax2) = calcEthQuoteToBuy(outputAmount);
            require(usedEth < msg.value, "usedEth too large");
            ethToRefund = msg.value - usedEth;

            totalEthTax += outEthTax2;
            ethBalance += usedEth - outEthTax2;
            ethReserve += usedEth - outEthTax2;
            tokenReserve -= outputAmount;
            outEthTaxG = outEthTax2;
        } else {
            // Positive slippage is bad.  Negative slippage is good.
            // Positive slippage means we will receive less token than estimated
            if(estOutputAmount > 0 && estOutputAmount > outputAmount) {
                require(estOutputAmount.sub(outputAmount) <= estOutputAmount.div(10000).mul(allowSlip), "Slippage too large");
            }
            totalEthTax += outEthTax1;
            ethBalance += msg.value - outEthTax1;
            ethReserve += msg.value - outEthTax1;
            tokenReserve -= outputAmount;
            outEthTaxG = outEthTax1;
        }

        int256 slippage = 0;
        if (estOutputAmount > 0) {
            slippage = int256(estOutputAmount) - int256(outputAmount);
        }

        bondedAmount = bondedAmount.add(outputAmount);
        priceBondCurve = getBondPrice();

        tmToken.transfer(receiver, outputAmount);
        if (outEthTaxG > 0) {
            payTradeFee(weth, outEthTaxG);
        }
        if (ethToRefund > 0) {
            require(ethToRefund <= msg.value, "ethToRefund too large");
            payable(receiver).transfer(ethToRefund);
        }

        if (maxBondedAmount - bondedAmount < 100000) {
            isBonded = true;
            IBigtokenHelper(bigtokenHelper).emitBondedEvent(address(tmToken), address(this).balance);
        }
        IBigtokenHelper(bigtokenHelper).emitTradeEvent(address(tmToken), receiver, outputAmount, (msg.value-ethToRefund), priceBondCurve, bondedAmount, "buy", slippage, ethReserve, tokenReserve);
    }

    /// @param _amount token amount to sell
    /// @param estAmountETH estimation of ETH amount
    /// @param allowSlip is a percentage represented as an percentage * 10^2 with a 2 decimal fixed point
    /// 1% would be uint256 representation of 100, 1.25% would be 125, 25.5% would be 2550
    function sellToken(uint256 _amount, uint256 estAmountETH, uint256 allowSlip) external nonReentrant {
        _sellToken(_amount, estAmountETH, allowSlip, msg.sender);
    }

    function sellTokenForAccount(uint256 _amount, address receiver) external onlyToken nonReentrant {
        _sellToken(_amount, 0, 0, receiver);
    }
    
    function _sellToken(uint256 _amount, uint256 estAmountETH, uint256 allowSlip, address receiver) internal {
        require(!isBonded, "The curve already bonded");
        require(isInitialized, "curve not init");
        require(_amount > 0, "Sell amount equal to zero");
        require(_amount <= bondedAmount, "Sell amount greater than bonded amount");
        require(_amount <= tmToken.allowance(msg.sender, address(this)), "miss allowance to spend?");

        (uint256 outEth, uint256 outEthTax) = calcEthQuoteToSell(_amount);

        // Positive slippage is bad.  Negative slippage is good.
        // Positive slippage means we will receive less than estimated
        if(estAmountETH > 0 && estAmountETH > outEth) {
            require(estAmountETH.sub(outEth) < estAmountETH.div(10000).mul(allowSlip), "Slippage > allowed");
        }

        int256 slippage = int256(estAmountETH) - int256(outEth);
        tmToken.transferFrom(msg.sender, address(this), _amount);

        totalEthTax += outEthTax;
        ethBalance = ethBalance - outEth - outEthTax;
        ethReserve = ethReserve - outEth - outEthTax;
        tokenReserve += _amount;
        bondedAmount = bondedAmount.sub(_amount);
        priceBondCurve = getBondPrice();

        if (outEthTax > 0) {
            payTradeFee(weth, outEthTax);
        }        
        payable(receiver).transfer(outEth);   // Transfer ETH to Sender
        IBigtokenHelper(bigtokenHelper).emitTradeEvent(address(tmToken), receiver, _amount, outEth, priceBondCurve, bondedAmount, "sell", slippage, ethReserve, tokenReserve);
    }

    function startDexTrade() external onlyHelper {
        uint256 ethBalanceOwned = address(this).balance;
        uint256 platformFee = payPlatformFee(weth, ethBalanceOwned);
        ethBalanceOwned = address(this).balance; //need to update, as deducted platformFee 

        tmToken.setStarted();

        IUniswapV2Router01 router = IUniswapV2Router01(uniswapRouter);
        uint256 toAddLpTmTokenAmount = tmToken.balanceOf(address(this));
        tmToken.approve(uniswapRouter, type(uint256).max);

        // add liquidity
        address tokenAddr = address(tmToken);
        (uint256 tokenAmount, uint256 ethAmount, uint256 liquidity) = router
            .addLiquidityETH{value: ethBalanceOwned}(
            tokenAddr, // token
            toAddLpTmTokenAmount, // token desired
            toAddLpTmTokenAmount, // token min
            ethBalanceOwned, // eth min
            address(this), // lp to
            block.timestamp + 1 days // deadline
        );
        _handleLP(pairAddr);
        IBigtokenHelper(bigtokenHelper).emitLaunchEvent(tokenAddr, address(this), pairAddr, tokenAmount, ethAmount, liquidity, platformFee);
    }

    function payPlatformFee(address _weth, uint256 ethAmount) internal returns (uint256 platformFee) {
        platformFee = ethAmount * platformFeePercent / 1000;
        if (platformFee == 0) {
            return 0;
        }
        IWETH(_weth).deposit{value: platformFee}();
        IWETH(_weth).transfer(getFeeDao(), platformFee);
    }

    function payTradeFee(address _weth, uint256 ethAmount) internal {
        if (ethAmount == 0) {
            return;
        }
        IWETH(_weth).deposit{value: ethAmount}();
        IWETH(_weth).transfer(getFeeDao(), ethAmount);
    }

    function _handleLP(address lp) internal {
        IERC20 lpToken = IERC20(lp);
        address deadAddress = address(0x000000000000000000000000000000000000dEaD);
        lpToken.safeTransfer(deadAddress, lpToken.balanceOf(address(this)));
    }

    function getFeeDao() public view returns (address) {
        return IBigtokenHelper(bigtokenHelper).feeDao();
    }

    //if contract have problem, force to unbond status
    function setUnbond() public onlyHelper {
        isBonded = false;
    }

    modifier onlyHelper() {
        require(msg.sender == bigtokenHelper, "forbidden1");
        _;
    }

    modifier onlyToken() {
        require(msg.sender == address(tmToken), "forbidden2");
        _;
    }
}
