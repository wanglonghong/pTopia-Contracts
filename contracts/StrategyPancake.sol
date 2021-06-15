// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

import "./interfaces/IBEP20.sol";
import "./interfaces/IPancakeswapFarm.sol";
import "./interfaces/IPancakeRouter02.sol";
import "./libraries/SafeBEP20.sol";

contract StrategyPancake is Ownable, ReentrancyGuard, Pausable {
    // Maximises yields in pancakeswap

    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    bool public isCAKEStaking; // only for staking CAKE using pancakeswap's native CAKE staking contract.
    bool public isNativeVault; // this vault is purely for staking. eg. WBNB-NATIVE staking vault.

    address public farmContractAddress; // address of farm, eg, PCS, Thugs etc.
    uint256 public pid; // pid of pool in farmContractAddress
    address public wantAddress;
    address public token0Address;
    address public token1Address;
    address public earnedAddress;
    address public uniRouterAddress; // uniswap, pancakeswap etc
    address public rewardPoolAddress;

    address public constant wbnbAddress =
        0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public nativeFarmAddress;
    address public NATIVEAddress;
    address public govAddress; // timelock contract
    bool public onlyGov = true;

    uint256 public lastEarnBlock = 0;
    uint256 public wantLockedTotal = 0;
    uint256 public sharesTotal = 0;

    uint256 public controllerFee = 20;
    uint256 public constant controllerFeeMax = 10000; // 100 = 1%
    uint256 public constant controllerFeeUL = 300;

    uint256 public depositFee = 50;
    uint256 public constant depositFeeMax = 10000; // 100 = 1%
    uint256 public constant depositFeeUL = 300;

    uint256 public buyBackRate = 80;
    uint256 public constant buyBackRateMax = 10000; // 100 = 1%
    uint256 public constant buyBackRateUL = 800;
    /* This is vanity address -  For instance an address 0x000000000000000000000000000000000000dEaD for which it's
       absolutely impossible to generate a private key with today's computers. */
    address public constant buyBackAddress = 0x000000000000000000000000000000000000dEaD;
    uint256 public entranceFeeFactor = 9990; // < 0.1% entrance fee - goes to pool + prevents front-running
    uint256 public constant entranceFeeFactorMax = 10000;
    uint256 public constant entranceFeeFactorLL = 9950; // 0.5% is the max entrance fee settable. LL = lowerlimit

    address[] public earnedToNATIVEPath;
    address[] public earnedToToken0Path;
    address[] public earnedToToken1Path;
    address[] public token0ToEarnedPath;
    address[] public token1ToEarnedPath;

    constructor(
        address _nativeFarmAddress,
        address _NATIVEAddress,
        bool _isCAKEStaking,
        bool _isNativeVault,
        address _farmContractAddress,
        uint256 _pid,
        address _wantAddress,
        address _token0Address,
        address _token1Address,
        address _earnedAddress,
        address _uniRouterAddress,
        address _rewardPoolAddress
    ) public {
        govAddress = msg.sender;
        nativeFarmAddress = _nativeFarmAddress;
        NATIVEAddress = _NATIVEAddress;
        rewardPoolAddress = _rewardPoolAddress;

        isCAKEStaking = _isCAKEStaking;
        isNativeVault = _isNativeVault;
        wantAddress = _wantAddress;

        if (isNativeVault) {
            if (!isCAKEStaking) {
                token0Address = _token0Address;
                token1Address = _token1Address;
            }

            farmContractAddress = _farmContractAddress;
            pid = _pid;
            earnedAddress = _earnedAddress;

            uniRouterAddress = _uniRouterAddress;

            earnedToNATIVEPath = [earnedAddress, wbnbAddress, NATIVEAddress];
            if (wbnbAddress == earnedAddress) {
                earnedToNATIVEPath = [wbnbAddress, NATIVEAddress];
            }

            earnedToToken0Path = [earnedAddress, wbnbAddress, token0Address];
            if (wbnbAddress == token0Address) {
                earnedToToken0Path = [earnedAddress, wbnbAddress];
            }

            earnedToToken1Path = [earnedAddress, wbnbAddress, token1Address];
            if (wbnbAddress == token1Address) {
                earnedToToken1Path = [earnedAddress, wbnbAddress];
            }

            token0ToEarnedPath = [token0Address, wbnbAddress, earnedAddress];
            if (wbnbAddress == token0Address) {
                token0ToEarnedPath = [wbnbAddress, earnedAddress];
            }

            token1ToEarnedPath = [token1Address, wbnbAddress, earnedAddress];
            if (wbnbAddress == token1Address) {
                token1ToEarnedPath = [wbnbAddress, earnedAddress];
            }
        }

        transferOwnership(nativeFarmAddress);
    }

    // Receives new deposits from user
    function deposit(address _userAddress, uint256 _wantAmt)
        public
        onlyOwner
        whenNotPaused
        returns (uint256)
    {
        IBEP20(wantAddress).safeTransferFrom(
            address(msg.sender),
            address(this),
            _wantAmt
        );

        if (depositFee < depositFeeMax) {
            uint256 _feeAmt = _wantAmt.mul(depositFee).div(depositFeeMax);
            _wantAmt = _wantAmt.sub(_feeAmt);
            IBEP20(wantAddress).safeTransfer(rewardPoolAddress, _feeAmt);
        }

        uint256 sharesAdded = _wantAmt;
        if (wantLockedTotal > 0) {
            sharesAdded = _wantAmt
                .mul(sharesTotal)
                .mul(entranceFeeFactor)
                .div(wantLockedTotal)
                .div(entranceFeeFactorMax);

            // Fix if pool stuck
            if (sharesAdded == 0 && sharesTotal == 0) {
                sharesAdded = _wantAmt
                    .mul(entranceFeeFactor)
                    .div(wantLockedTotal)
                    .div(entranceFeeFactorMax);
            }
        }
        sharesTotal = sharesTotal.add(sharesAdded);

        if (isNativeVault) {
            _farm();
        } else {
            wantLockedTotal = wantLockedTotal.add(_wantAmt);
        }

        return sharesAdded;
    }

    function farm() public nonReentrant {
        _farm();
    }

    function _farm() internal {
        uint256 wantAmt = IBEP20(wantAddress).balanceOf(address(this));
        wantLockedTotal = wantLockedTotal.add(wantAmt);
        IBEP20(wantAddress).safeIncreaseAllowance(farmContractAddress, wantAmt);

        if (isCAKEStaking) {
            IPancakeswapFarm(farmContractAddress).enterStaking(wantAmt); // Just for CAKE staking, we dont use deposit()
        } else {
            IPancakeswapFarm(farmContractAddress).deposit(pid, wantAmt);
        }
    }

    function withdraw(address _userAddress, uint256 _wantAmt)
        public
        onlyOwner
        nonReentrant
        returns (uint256)
    {
        require(_wantAmt > 0, "_wantAmt <= 0");

        if (isNativeVault) {
            if (isCAKEStaking) {
                IPancakeswapFarm(farmContractAddress).leaveStaking(_wantAmt); // Just for CAKE staking, we dont use withdraw()
            } else {
                IPancakeswapFarm(farmContractAddress).withdraw(pid, _wantAmt);
            }
        }

        uint256 wantAmt = IBEP20(wantAddress).balanceOf(address(this));
        if (_wantAmt > wantAmt) {
            _wantAmt = wantAmt;
        }

        if (wantLockedTotal < _wantAmt) {
            _wantAmt = wantLockedTotal;
        }

        uint256 sharesRemoved = _wantAmt.mul(sharesTotal).div(wantLockedTotal);
        if (sharesRemoved > sharesTotal) {
            sharesRemoved = sharesTotal;
        }
        sharesTotal = sharesTotal.sub(sharesRemoved);
        wantLockedTotal = wantLockedTotal.sub(_wantAmt);

        IBEP20(wantAddress).safeTransfer(nativeFarmAddress, _wantAmt);

        return sharesRemoved;
    }

    // 1. Harvest farm tokens
    // 2. Converts farm tokens into want tokens
    // 3. Deposits want tokens

    function earn() public whenNotPaused {
        require(isNativeVault, "!isNativeVault");
        if (onlyGov) {
            require(msg.sender == govAddress, "Not authorised");
        }

        // Harvest farm tokens
        if (isCAKEStaking) {
            IPancakeswapFarm(farmContractAddress).leaveStaking(0); // Just for CAKE staking, we dont use withdraw()
        } else {
            IPancakeswapFarm(farmContractAddress).withdraw(pid, 0);
        }

        // Converts farm tokens into want tokens
        uint256 earnedAmt = IBEP20(earnedAddress).balanceOf(address(this));

        earnedAmt = distributeFees(earnedAmt);
        earnedAmt = buyBack(earnedAmt);

        if (isCAKEStaking) {
            lastEarnBlock = block.number;
            _farm();
            return;
        }

        IBEP20(earnedAddress).safeIncreaseAllowance(
            uniRouterAddress,
            earnedAmt
        );

        if (earnedAddress != token0Address) {
            // Swap half earned to token0
            IPancakeRouter02(uniRouterAddress)
                .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                earnedAmt.div(2),
                0,
                earnedToToken0Path,
                address(this),
                now + 60
            );
        }

        if (earnedAddress != token1Address) {
            // Swap half earned to token1
            IPancakeRouter02(uniRouterAddress)
                .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                earnedAmt.div(2),
                0,
                earnedToToken1Path,
                address(this),
                now + 60
            );
        }

        // Get want tokens, ie. add liquidity
        uint256 token0Amt = IBEP20(token0Address).balanceOf(address(this));
        uint256 token1Amt = IBEP20(token1Address).balanceOf(address(this));
        if (token0Amt > 0 && token1Amt > 0) {
            IBEP20(token0Address).safeIncreaseAllowance(
                uniRouterAddress,
                token0Amt
            );
            IBEP20(token1Address).safeIncreaseAllowance(
                uniRouterAddress,
                token1Amt
            );
            IPancakeRouter02(uniRouterAddress).addLiquidity(
                token0Address,
                token1Address,
                token0Amt,
                token1Amt,
                0,
                0,
                address(this),
                now + 60
            );
        }

        lastEarnBlock = block.number;

        _farm();
    }

    function buyBack(uint256 _earnedAmt) internal returns (uint256) {
        if (buyBackRate <= 0) {
            return _earnedAmt;
        }

        uint256 buyBackAmt = _earnedAmt.mul(buyBackRate).div(buyBackRateMax);

        IBEP20(earnedAddress).safeIncreaseAllowance(
            uniRouterAddress,
            buyBackAmt
        );

        IPancakeRouter02(uniRouterAddress)
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(
            buyBackAmt,
            0,
            earnedToNATIVEPath,
            buyBackAddress,
            now + 60
        );

        return _earnedAmt.sub(buyBackAmt);
    }

    function distributeFees(uint256 _earnedAmt) internal returns (uint256) {
        if (_earnedAmt > 0) {
            // Performance fee
            if (controllerFee > 0) {
                uint256 fee =
                    _earnedAmt.mul(controllerFee).div(controllerFeeMax);
                IBEP20(earnedAddress).safeTransfer(govAddress, fee);
                _earnedAmt = _earnedAmt.sub(fee);
            }
        }

        return _earnedAmt;
    }

    function convertDustToEarned() public whenNotPaused {
        require(isNativeVault, "!isNativeVault");
        require(!isCAKEStaking, "isCAKEStaking");

        // Converts dust tokens into earned tokens, which will be reinvested on the next earn().

        // Converts token0 dust (if any) to earned tokens
        uint256 token0Amt = IBEP20(token0Address).balanceOf(address(this));
        if (token0Address != earnedAddress && token0Amt > 0) {
            IBEP20(token0Address).safeIncreaseAllowance(
                uniRouterAddress,
                token0Amt
            );

            // Swap all dust tokens to earned tokens
            IPancakeRouter02(uniRouterAddress)
                .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                token0Amt,
                0,
                token0ToEarnedPath,
                address(this),
                now + 60
            );
        }

        // Converts token1 dust (if any) to earned tokens
        uint256 token1Amt = IBEP20(token1Address).balanceOf(address(this));
        if (token1Address != earnedAddress && token1Amt > 0) {
            IBEP20(token1Address).safeIncreaseAllowance(
                uniRouterAddress,
                token1Amt
            );

            // Swap all dust tokens to earned tokens
            IPancakeRouter02(uniRouterAddress)
                .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                token1Amt,
                0,
                token1ToEarnedPath,
                address(this),
                now + 60
            );
        }
    }

    function pause() public {
        require(msg.sender == govAddress, "Not authorised");
        _pause();
    }

    function unpause() external {
        require(msg.sender == govAddress, "Not authorised");
        _unpause();
    }

    function setEntranceFeeFactor(uint256 _entranceFeeFactor) public {
        require(msg.sender == govAddress, "Not authorised");
        require(_entranceFeeFactor > entranceFeeFactorLL, "!safe - too low");
        require(_entranceFeeFactor <= entranceFeeFactorMax, "!safe - too high");
        entranceFeeFactor = _entranceFeeFactor;
    }

    function setControllerFee(uint256 _controllerFee) public {
        require(msg.sender == govAddress, "Not authorised");
        require(_controllerFee <= controllerFeeUL, "too high");
        controllerFee = _controllerFee;
    }

    function setDepositFee(uint256 _depositFee) public {
        require(msg.sender == govAddress, "Not authorised");
        require(_depositFee <= depositFeeUL, "too high");
        depositFee = _depositFee;
    }    

    function setbuyBackRate(uint256 _buyBackRate) public {
        require(msg.sender == govAddress, "Not authorised");
        require(buyBackRate <= buyBackRateUL, "too high");
        buyBackRate = _buyBackRate;
    }

    function setGov(address _govAddress) public {
        require(msg.sender == govAddress, "!gov");
        govAddress = _govAddress;
    }

    function setOnlyGov(bool _onlyGov) public {
        require(msg.sender == govAddress, "!gov");
        onlyGov = _onlyGov;
    }

    function inCaseTokensGetStuck(
        address _token,
        uint256 _amount,
        address _to
    ) public {
        require(msg.sender == govAddress, "!gov");
        require(_token != earnedAddress, "!safe");
        require(_token != wantAddress, "!safe");
        IBEP20(_token).safeTransfer(_to, _amount);
    }
}
