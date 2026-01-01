pragma solidity ^0.8.30;

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }
}

abstract contract Ownable is Context {
    address private _owner;
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    
    constructor() {
        _transferOwnership(_msgSender());
    }
    
    modifier onlyOwner() {
        _checkOwner();
        _;
    }
    
    function owner() public view virtual returns (address) {
        return _owner;
    }
    
    function _checkOwner() internal view virtual {
        require(owner() == _msgSender(), "Ownable: caller is not the owner");
    }
    
    function _transferOwnership(address newOwner) internal virtual {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}

abstract contract ReentrancyGuard {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status;

    constructor() {
        _status = _NOT_ENTERED;
    }

    modifier nonReentrant() {
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}

// MAIN CONTRACT
contract TITAN is ReentrancyGuard, Ownable {
    IERC20 public usdtToken;
    
    struct InvestmentPlan {
        uint256 minAmount;
        uint256 maxAmount;
        uint256 dailyROI;
        uint256 duration;
        uint256 totalROI;
    }
    
    struct UserInvestment {
        uint256 amount;
        uint256 planId;
        uint256 startTime;
        uint256 lastWithdrawalTime;
        uint256 totalWithdrawn;
        bool active;
    }
    
    struct User {
        address upline;
        uint256 totalDeposits;
        uint256 totalWithdrawn;
        uint256 directReferrals;
        uint256 referralBonus;
        uint256 lastWithdrawal;
        UserInvestment[] investments;
        bool exists;
    }
    
    struct ReferralLevel {
        uint256 percentage;
        uint256 minDirectReferrals;
    }
    
    uint256 public constant OWNER_FEE_PERCENT = 1000;
    uint256 public constant WITHDRAWAL_FEE_PERCENT = 500;
    uint256 public constant MIN_DEPOSIT = 20 * 10**18;
    uint256 public constant MIN_WITHDRAWAL = 1 * 10**18;
    uint256 public constant DAILY_WITHDRAWAL_LIMIT = 1000 * 10**18;
    uint256 public constant TIME_STEP = 1 days;
    uint256 public constant MIN_ACTIVE_INVESTMENT = 20 * 10**18;

    InvestmentPlan[] public investmentPlans;
    ReferralLevel[] public referralLevels;
    
    mapping(address => User) public users;
    mapping(address => mapping(uint256 => uint256)) public dailyWithdrawals;
    
    uint256 public totalReferralBonuses;
    uint256 public totalExpiredReferralBonuses;
    uint256 public totalWithdrawalFees;

    event Deposit(address indexed user, uint256 amount, uint256 planId, address upline);
    event Withdraw(address indexed user, uint256 amount, uint256 fee);
    event ReferralBonus(address indexed user, address indexed referral, uint256 level, uint256 amount);
    event ReferralBonusExpired(address indexed referral, uint256 amount, address owner);
    event PoolWithdrawn(address indexed owner, uint256 totalBalance);

    constructor(address _usdtToken) {
        usdtToken = IERC20(_usdtToken);
        
        investmentPlans.push(InvestmentPlan(20 * 10**18, 499 * 10**18, 100, 150, 150));
        investmentPlans.push(InvestmentPlan(500 * 10**18, 1999 * 10**18, 120, 150, 180));
        investmentPlans.push(InvestmentPlan(2000 * 10**18, 4999 * 10**18, 150, 150, 225));
        investmentPlans.push(InvestmentPlan(5000 * 10**18, 9999 * 10**18, 180, 150, 270));
        investmentPlans.push(InvestmentPlan(10000 * 10**18, type(uint256).max, 200, 150, 300));
        
        referralLevels.push(ReferralLevel(500, 0));
        referralLevels.push(ReferralLevel(300, 10));
        referralLevels.push(ReferralLevel(100, 15));
        referralLevels.push(ReferralLevel(100, 20));
        
        users[msg.sender].exists = true;
    }
    
    function deposit(uint256 _amount, uint256 _planId, address _upline) external nonReentrant {
        require(_amount >= MIN_DEPOSIT, "Deposit below minimum");
        require(_planId < investmentPlans.length, "Invalid plan ID");
        
        InvestmentPlan memory plan = investmentPlans[_planId];
        require(_amount >= plan.minAmount && _amount <= plan.maxAmount, "Amount not in plan range");
        
        if (!users[msg.sender].exists) {
            users[msg.sender].exists = true;
            users[msg.sender].lastWithdrawal = block.timestamp;
            
            if (_upline != address(0) && _upline != msg.sender && users[_upline].exists) {
                users[msg.sender].upline = _upline;
                users[_upline].directReferrals++;
            }
        }
        
        require(usdtToken.transferFrom(msg.sender, address(this), _amount), "Transfer failed");
        
        uint256 ownerFee = (_amount * OWNER_FEE_PERCENT) / 10000;
        require(usdtToken.transfer(owner(), ownerFee), "Owner fee transfer failed");
        
        UserInvestment memory newInvestment = UserInvestment({
            amount: _amount,
            planId: _planId,
            startTime: block.timestamp,
            lastWithdrawalTime: block.timestamp,
            totalWithdrawn: 0,
            active: true
        });
        
        users[msg.sender].investments.push(newInvestment);
        users[msg.sender].totalDeposits += _amount;
        
        _distributeReferralBonus(_amount, msg.sender);
        
        emit Deposit(msg.sender, _amount, _planId, users[msg.sender].upline);
    }
    
    function withdraw() external nonReentrant {
        require(users[msg.sender].exists, "User not registered");
        require(block.timestamp >= users[msg.sender].lastWithdrawal + TIME_STEP, "Withdrawal too soon");
        
        uint256 totalAvailable = calculateAvailableEarnings(msg.sender);
        require(totalAvailable >= MIN_WITHDRAWAL, "Below minimum withdrawal");
        
        uint256 today = block.timestamp / TIME_STEP;
        uint256 alreadyWithdrawnToday = dailyWithdrawals[msg.sender][today];
        uint256 availableToday = DAILY_WITHDRAWAL_LIMIT - alreadyWithdrawnToday;
        
        if (totalAvailable > availableToday) {
            totalAvailable = availableToday;
        }
        
        require(totalAvailable >= MIN_WITHDRAWAL, "Available below minimum after daily limit");
        
        uint256 withdrawalFee = (totalAvailable * WITHDRAWAL_FEE_PERCENT) / 10000;
        uint256 netAmount = totalAvailable - withdrawalFee;
        totalWithdrawalFees += withdrawalFee;
        
        users[msg.sender].lastWithdrawal = block.timestamp;
        users[msg.sender].totalWithdrawn += netAmount;
        dailyWithdrawals[msg.sender][today] += netAmount;
        
        _updateWithdrawals(msg.sender, totalAvailable);
        
        require(usdtToken.transfer(msg.sender, netAmount), "Withdrawal transfer failed");
        
        emit Withdraw(msg.sender, netAmount, withdrawalFee);
    }
    
    function calculateAvailableEarnings(address _user) public view returns (uint256) {
        if (!users[_user].exists) return 0;
        
        uint256 totalEarnings = 0;
        
        for (uint256 i = 0; i < users[_user].investments.length; i++) {
            UserInvestment memory investment = users[_user].investments[i];
            if (!investment.active) continue;
            
            InvestmentPlan memory plan = investmentPlans[investment.planId];
            
            uint256 timePassed = block.timestamp - investment.lastWithdrawalTime;
            uint256 daysPassed = timePassed / TIME_STEP;
            
            if (daysPassed > 0) {
                uint256 dailyEarning = (investment.amount * plan.dailyROI) / 10000;
                uint256 maxEarning = (investment.amount * plan.totalROI) / 100;
                uint256 remainingEarning = maxEarning - investment.totalWithdrawn;
                
                uint256 available = dailyEarning * daysPassed;
                if (available > remainingEarning) {
                    available = remainingEarning;
                }
                
                totalEarnings += available;
            }
        }
        
        totalEarnings += users[_user].referralBonus;
        
        return totalEarnings;
    }
    
    function _distributeReferralBonus(uint256 _amount, address _referral) private {
        address currentUpline = users[_referral].upline;
        
        for (uint256 i = 0; i < referralLevels.length; i++) {
            if (currentUpline == address(0)) break;
            
            ReferralLevel memory level = referralLevels[i];
            
            if (users[currentUpline].directReferrals >= level.minDirectReferrals && 
                _hasActiveInvestment(currentUpline)) {
                
                uint256 bonus = (_amount * level.percentage) / 10000;
                users[currentUpline].referralBonus += bonus;
                totalReferralBonuses += bonus;
                
                emit ReferralBonus(currentUpline, _referral, i + 1, bonus);
                
            } else if (users[currentUpline].directReferrals >= level.minDirectReferrals) {
                uint256 expiredBonus = (_amount * level.percentage) / 10000;
                totalExpiredReferralBonuses += expiredBonus;
                
                emit ReferralBonusExpired(_referral, expiredBonus, owner());
            }
            
            currentUpline = users[currentUpline].upline;
        }
    }
    
    function _hasActiveInvestment(address _user) private view returns (bool) {
        if (!users[_user].exists) return false;
        
        for (uint256 i = 0; i < users[_user].investments.length; i++) {
            UserInvestment memory investment = users[_user].investments[i];
            if (investment.active && investment.amount >= MIN_ACTIVE_INVESTMENT) {
                InvestmentPlan memory plan = investmentPlans[investment.planId];
                if (block.timestamp <= investment.startTime + (plan.duration * TIME_STEP)) {
                    return true;
                }
            }
        }
        return false;
    }
    
    function _updateWithdrawals(address _user, uint256 _withdrawnAmount) private {
        uint256 remaining = _withdrawnAmount;
        
        if (users[_user].referralBonus > 0) {
            if (remaining <= users[_user].referralBonus) {
                users[_user].referralBonus -= remaining;
                remaining = 0;
            } else {
                remaining -= users[_user].referralBonus;
                users[_user].referralBonus = 0;
            }
        }
        
        if (remaining > 0) {
            for (uint256 i = 0; i < users[_user].investments.length && remaining > 0; i++) {
                UserInvestment storage investment = users[_user].investments[i];
                if (!investment.active) continue;
                
                InvestmentPlan memory plan = investmentPlans[investment.planId];
                uint256 maxEarning = (investment.amount * plan.totalROI) / 100;
                uint256 remainingEarning = maxEarning - investment.totalWithdrawn;
                
                if (remainingEarning == 0) {
                    investment.active = false;
                    continue;
                }
                
                uint256 timePassed = block.timestamp - investment.lastWithdrawalTime;
                uint256 daysPassed = timePassed / TIME_STEP;
                
                if (daysPassed > 0) {
                    uint256 dailyEarning = (investment.amount * plan.dailyROI) / 10000;
                    uint256 available = dailyEarning * daysPassed;
                    
                    if (available > remainingEarning) {
                        available = remainingEarning;
                    }
                    
                    uint256 toWithdraw = available > remaining ? remaining : available;
                    
                    investment.totalWithdrawn += toWithdraw;
                    investment.lastWithdrawalTime += daysPassed * TIME_STEP;
                    remaining -= toWithdraw;
                    
                    if (investment.totalWithdrawn >= maxEarning) {
                        investment.active = false;
                    }
                }
            }
        }
    }
    
    function withdrawExpiredBonuses() external onlyOwner {
        uint256 contractBalance = usdtToken.balanceOf(address(this));
        require(contractBalance > 0, "No balance to withdraw");
        
        totalExpiredReferralBonuses = 0;
        
        require(usdtToken.transfer(owner(), contractBalance), "Withdrawal failed");
        
        emit PoolWithdrawn(owner(), contractBalance);
    }

    function getUserInvestments(address _user) external view returns (UserInvestment[] memory) {
        return users[_user].investments;
    }
    
    function getUserInfo(address _user) external view returns (
        uint256 totalDeposits,
        uint256 totalWithdrawn,
        uint256 directReferrals,
        uint256 referralBonus,
        uint256 availableEarnings,
        address upline,
        bool hasActiveInvestment
    ) {
        User memory user = users[_user];
        return (
            user.totalDeposits,
            user.totalWithdrawn,
            user.directReferrals,
            user.referralBonus,
            calculateAvailableEarnings(_user),
            user.upline,
            _hasActiveInvestment(_user)
        );
    }
    
    function getPlansCount() external view returns (uint256) {
        return investmentPlans.length;
    }
    
    function getContractBalance() external view returns (uint256) {
        return usdtToken.balanceOf(address(this));
    }
    
    function getContractStats() external view returns (
        uint256 totalExpiredBonuses,
        uint256 totalWithdrawalFeesCollected,
        uint256 totalReferralBonusesPaid,
        uint256 currentContractBalance
    ) {
        return (
            totalExpiredReferralBonuses,
            totalWithdrawalFees,
            totalReferralBonuses,
            usdtToken.balanceOf(address(this))
        );
    }
    
    function getActiveInvestmentStatus(address _user) external view returns (bool) {
        return _hasActiveInvestment(_user);
    }
}
