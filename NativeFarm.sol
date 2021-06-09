// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./interfaces/IBEP20.sol";
import "./interfaces/IReferral.sol";

import "./helpers/ReentrancyGuard.sol";
import "./helpers/Pausable.sol";
import "./helpers/Ownable.sol";

import "./libraries/SafeBEP20.sol";
import "NativeToken.sol";

contract NativeFarm is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    /// @notice Info of each user.
    struct UserInfo {
        uint256 shares;             // How many LP tokens the user has provided.
        uint256 rewardDebt;         // Reward debt. See explanation below.
        uint256 rewardLockedUp;     // Rewards locked by harvest intervl.
        uint256 nextHarvestUntil;   // When can the user harvest again.

        // We do some fancy math here. Basically, any point in time, the amount of AUTO
        // entitled to a user but is pending to be distributed is:
        //
        //   amount = user.shares / sharesTotal * wantLockedTotal
        //   pending reward = (amount * pool.accNATIVEPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws want tokens to a pool. Here's what happens:
        //   1. The pool's `accNATIVEPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    /// @notice Info of each pool
    struct PoolInfo {
        IBEP20 want;                    // Address of the want token.
        uint256 allocPoint;             // How many allocation points assigned to this pool. NATIVE to distribute per block.
        uint256 lastRewardBlock;        // Last block number that NATIVE distribution occurs.
        uint256 accNATIVEPerShare;      // Accumulated NATIVE per share, times 1e12. See below.
        uint256 harvestInterval;        // Harvest interval in seconds.
        address strategy;               // Strategy address that will auto compound want tokens
    }

    // Token address
    address public NATIVE;
    // Owner reward per block: 10% ==> 11.11%
    uint256 public ownerNATIVEReward = 1111;
    // Native total supply: 2.2 mil = 2200000e18
    uint256 public NATIVEMaxSupply = 2000000e18;
    // Natives per block: (0.204528125 - owner 10%)
    uint256 public NATIVEPerBlock = 204528125000000000; // NATIVE tokens created per block
    /// block number when vaults start
    uint256 public startBlock;
    // Maximum harvest interval: 14 days
    uint256 public MAXIMUM_HARVEST_INTERVAL = 14 days;   
    // Total rewards locked by harvest interval
    uint256 public totalLockedUpRewards;
    // Native referral contract
    IReferral public nativeReferral;
    // Maximum referral commission rate
    uint256 public MAXIMUM_REFERRAL_COMMISSION_RATE = 1000;
    // Referral commission rate
    uint256 public referralCommissionRate = 100;

    PoolInfo[] public poolInfo; // Info of each pool.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo; // Info of each user that stakes LP tokens.
    uint256 public totalAllocPoint = 0; // Total allocation points. Must be the sum of all allocation points in all pools.

    /// @notice Emitted when a user deposits the fund to the vault
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);

    /// @notice Emitted when a user withdraws the reward from the vault
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);

    /// @notice Emitted when a user withdraws during the locking period
    event RewardLockedUp(address indexed user, uint256 indexed pid, uint256 amountLockedUp);    

    /// @notice Emitted when a user withdraw accidently
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

    /// @notice Emitted when a referrer is paid.
    event ReferralPaid(address indexed user, address indexed referrer, uint256 amount);

    constructor (
        NativeToken _nativeToken,
        uint256 _startBlock,
    ) public {
        NATIVE = _nativeToken;
        startBlock = _startBlock;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do. (Only if want tokens are stored here.)
    function add(
        uint256 _allocPoint,
        IBEP20 _want,
        address _strategy,
        uint256 _harvestInterval,
        bool _withUpdate
    ) public onlyOwner {
        require(_harvestInterval <= MAXIMUM_HARVEST_INTERVAL, "add: invalid harvest interval");
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(
            PoolInfo({
                want: _want,
                allocPoint: _allocPoint,
                lastRewardBlock: lastRewardBlock,
                accNATIVEPerShare: 0,
                strategy: _strategy,
                harvestInterval: _harvestInterval
            })
        );
    }

    // Update the given pool's NATIVE allocation point. Can only be called by the owner.
    function set(
        uint256 _pid,
        uint256 _allocPoint,
        uint256 _harvestInterval,
        bool _withUpdate
    ) public onlyOwner {
        require(_harvestInterval <= MAXIMUM_HARVEST_INTERVAL, "set: invalid harvest interval");
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(
            _allocPoint
        );
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].harvestInterval = _harvestInterval;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to)
        public
        view
        returns (uint256)
    {
        if (IBEP20(NATIVE).totalSupply() >= NATIVEMaxSupply) {
            return 0;
        }
        return _to.sub(_from);
    }

    // View function to see pending AUTO on frontend.
    function pendingNATIVE(uint256 _pid, address _user)
        external
        view
        returns (uint256)
    {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accNATIVEPerShare = pool.accNATIVEPerShare;
        uint256 sharesTotal = IStrategy(pool.strategy).sharesTotal();
        if (block.number > pool.lastRewardBlock && sharesTotal != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 NATIVEReward =
                multiplier.mul(NATIVEPerBlock)
                          .mul(pool.allocPoint)
                          .div(totalAllocPoint);
            accNATIVEPerShare = accNATIVEPerShare.add(
                NATIVEReward.mul(1e12).div(sharesTotal)
            );
        }
        return user.shares.mul(accNATIVEPerShare).div(1e12).sub(user.rewardDebt);
    }

    // View function to see staked Want tokens on frontend.
    function stakedWantTokens(uint256 _pid, address _user)
        external
        view
        returns (uint256)
    {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];

        uint256 sharesTotal = IStrategy(pool.strategy).sharesTotal();
        uint256 wantLockedTotal =
            IStrategy(poolInfo[_pid].strategy).wantLockedTotal();
        if (sharesTotal == 0) {
            return 0;
        }
        return user.shares.mul(wantLockedTotal).div(sharesTotal);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 sharesTotal = IStrategy(pool.strategy).sharesTotal();
        if (sharesTotal == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        if (multiplier <= 0) {
            return;
        }
        uint256 NATIVEReward =
            multiplier.mul(NATIVEPerBlock).mul(pool.allocPoint).div(
                totalAllocPoint
            );

        NATIVEToken(NATIVE).mint(
            owner(),
            NATIVEReward.mul(ownerNATIVEReward).div(10000)
        );
        NATIVEToken(NATIVE).mint(address(this), NATIVEReward);

        pool.accNATIVEPerShare = pool.accNATIVEPerShare.add(
            NATIVEReward.mul(1e12).div(sharesTotal)
        );
        pool.lastRewardBlock = block.number;
    }

    // Want tokens moved from user -> AUTOFarm (AUTO allocation) -> Strat (compounding)
    function deposit(uint256 _pid, uint256 _wantAmt) public nonReentrant {
        updatePool(_pid);
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        payOrLockupPendingNative(_pid);

        if (_wantAmt > 0) {
            pool.want.safeTransferFrom(
                address(msg.sender), 
                address(this),
                _wantAmt
            );

            pool.want.safeIncreaseAllowance(pool.strategy, _wantAmt);
            uint256 sharesAdded =
                IStrategy(poolInfo[_pid].strategy).deposit(msg.sender, _wantAmt);
            user.shares = user.shares.add(sharesAdded);
        }
        user.rewardDebt = user.shares.mul(pool.accNATIVEPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _wantAmt);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _wantAmt) public nonReentrant {
        updatePool(_pid);

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        uint256 wantLockedTotal =
            IStrategy(poolInfo[_pid].strategy).wantLockedTotal();
        uint256 sharesTotal = IStrategy(poolInfo[_pid].strategy).sharesTotal();

        require(user.shares > 0, "withdraw: user.shares is 0");
        require(sharesTotal > 0, "withdraw: sharesTotal is 0");

        payOrLockupPendingNative(_pid);

        // Withdraw want tokens
        uint256 amount = user.shares.mul(wantLockedTotal).div(sharesTotal);
        if (_wantAmt > amount) {
            _wantAmt = amount;
        }
        if (_wantAmt > 0) {
            uint256 sharesRemoved =
                IStrategy(poolInfo[_pid].strategy).withdraw(msg.sender, _wantAmt);

            if (sharesRemoved > user.shares) {
                user.shares = 0;
            } else {
                user.shares = user.shares.sub(sharesRemoved);
            }

            uint256 wantBal = IBEP20(pool.want).balanceOf(address(this));
            if (wantBal < _wantAmt) {
                _wantAmt = wantBal;
            }
            pool.want.safeTransfer(address(msg.sender), _wantAmt);
        }
        user.rewardDebt = user.shares.mul(pool.accNATIVEPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _wantAmt);
    }

    function withdrawAll(uint256 _pid) public nonReentrant {
        withdraw(_pid, uint256(-1));
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        uint256 wantLockedTotal =
            IStrategy(poolInfo[_pid].strategy).wantLockedTotal();
        uint256 sharesTotal = IStrategy(poolInfo[_pid].strategy).sharesTotal();
        uint256 amount = user.shares.mul(wantLockedTotal).div(sharesTotal);

        IStrategy(poolInfo[_pid].strategy).withdraw(msg.sender, amount);
        pool.want.safeTransfer(address(msg.sender), amount);
        user.shares = 0;
        user.rewardDebt = 0;
        user.nextHarvestUntil = 0;

        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    // Pay or lockup pending NATIVEs.
    function payOrLockupPendingNative(uint256 _pid) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        if (user.nextHarvestUntil == 0) {
            user.nextHarvestUntil = block.timestamp.add(pool.harvestInterval);
        }

        uint256 pending = user.shares.mul(pool.accNATIVEPerShare).div(1e12).sub(user.rewardDebt);
        if (canHarvest(_pid, msg.sender)) {
            if (pending > 0 || user.rewardLockedUp > 0) {
                uint256 totalRewards = pending.add(user.rewardLockedUp);

                // reset lockup
                totalLockedUpRewards = totalLockedUpRewards.sub(user.rewardLockedUp);
                user.rewardLockedUp = 0;
                user.nextHarvestUntil = block.timestamp.add(pool.harvestInterval);

                // send rewards
                safeNATIVETransfer(msg.sender, totalRewards);
                payReferralCommission(msg.sender, totalRewards);
            }
        } else if (pending > 0) {
            user.rewardLockedUp = user.rewardLockedUp.add(pending);
            totalLockedUpRewards = totalLockedUpRewards.add(pending);
            emit RewardLockedUp(msg.sender, _pid, pending);
        }
    }

    function payReferralCommission(address _user, uint256 _pending) internal {
        if (address(nativeReferral) != address(0) && referralCommissionRate > 0) {
            address referrer = nativeReferral.getReferrer(_user);
            uint256 commissionAmount = _pending.mul(referralCommissionRate).div(10000);
            if (referrer != address(0) && commissionAmount > 0) {
                NATIVEToken(NATIVE).mint(referrer, commissionAmount);
                nativeReferral.recordReferralCommission(referrer, commissionAmount);

                emit ReferralPaid(_user, referrer, commissionAmount);
            }
        }
    }    

    // Safe AUTO transfer function, just in case if rounding error causes pool to not have enough
    function safeNATIVETransfer(address _to, uint256 _NATIVEAmt) internal {
        uint256 NATIVEBal = IBEP20(NATIVE).balanceOf(address(this));
        if (_NATIVEAmt > NATIVEBal) {
            IBEP20(NATIVE).transfer(_to, NATIVEBal);
        } else {
            IBEP20(NATIVE).transfer(_to, _NATIVEAmt);
        }
    }

    // View function to see if user can harvest tokens.
    function canHarvest(uint256 _pid, address _user) public view returns (bool) {
        UserInfo storage user = userInfo[_pid][_user];
        return block.timestamp >= user.nextHarvestUntil;
    }

    function setReferral(IReferral _nativeReferral) external onlyOwner {
        nativeReferral = _nativeReferral;
    }

    function setReferralCommissionRate(uint256 _referralCommissionRate) external onlyOwner {
        require(_referralCommissionRate <= MAXIMUM_REFERRAL_COMMISSION_RATE, "setReferralCommissionRate: The commission rate exceeds the maximum allowance");
        referralCommissionRate = _referralCommissionRate;
    }

    function inCaseTokensGetStuck(address _token, uint256 _amount)
        public
        onlyOwner
    {
        require(_token != NATIVE, "!safe");
        IBEP20(_token).safeTransfer(msg.sender, _amount);
    }
}
