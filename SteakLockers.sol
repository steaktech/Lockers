// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/* ------------------------------------------------------------
 *  IMPORTED MODULES
 * ------------------------------------------------------------ */
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./KitchenTimelock.sol";

/* ------------------------------------------------------------
 *  CONTRACT: SteakLockers
 * ------------------------------------------------------------
 *  @notice LP + ERC20 + Vesting locker system used by the Steakhouse ecosystem.
 *  - Locks LP tokens at graduation (authorized-only)
 *  - Supports generic ERC20 locks and vesting schedules (public)
 *  - Creator-controlled extension and transfer mechanics
 *  - Configurable fees and minimum lock durations
 * ------------------------------------------------------------ */
contract SteakLockers is ReentrancyGuard, KitchenTimelock {
    using SafeERC20 for IERC20;

    /* ------------------------------------------------------------
     *  STRUCTS — LP + ERC20 + Vesting
     * ------------------------------------------------------------ */
    struct Lock {
        uint256 amount;
        uint256 unlockTime;
        address owner;
    }

    struct ERC20Lock {
        uint256 amount;
        uint256 unlockTime;
        address owner;
    }

    struct ERC20VestingLock {
        uint256 amount; // total amount locked
        uint256 startTime; // when vesting starts
        uint256 initialUnlockDate; // first unlock date
        uint256 releaseInterval; // seconds between partial unlocks
        uint256 releasePercent; // % released per interval
        uint256 amountWithdrawn; // total amount claimed
        address owner;
        bool active;
    }

    /* ------------------------------------------------------------
     *  STATE VARIABLES
     * ------------------------------------------------------------ */
    mapping(address => Lock) public lpLocks;
    address[] public lockedTokens;

    // ERC20 standard locks
    mapping(address => uint256) public erc20LockCount;
    mapping(address => mapping(uint256 => ERC20Lock)) public erc20Locks;
    mapping(address => uint256[]) public erc20LockIdsByToken;

    // Vesting locks
    mapping(address => uint256) public vestingLockCount;
    mapping(address => mapping(uint256 => ERC20VestingLock)) public vestingLocks;
    mapping(address => uint256[]) public vestingLockIdsByToken;

    address public immutable steakhouseTreasury;
    address public authorizedCaller;
    address public owner;

    uint256 public lockFee = 0.08 ether;
    uint256 public erc20LockFee = 0.0025 ether;
    uint256 public minLpLockTime = 30 days;
    uint256 public minTokenLockTime = 1 days;

    /* ------------------------------------------------------------
     *  EVENTS
     * ------------------------------------------------------------ */
    // LP Locks
    event Locked(address indexed token, address indexed owner, uint256 amount, uint256 unlockTime);
    event Unlocked(address indexed token, address indexed owner, uint256 amount);
    event LockExtended(address indexed token, uint256 newUnlockTime);
    event LockTransferred(address indexed token, address oldOwner, address newOwner);

    // ERC20 Locks
    event ERC20Locked(
        address indexed token, uint256 indexed lockId, address indexed owner, uint256 amount, uint256 unlockTime
    );
    event ERC20Unlocked(address indexed token, uint256 indexed lockId, address indexed owner, uint256 amount);
    event ERC20LockExtended(address indexed token, uint256 indexed lockId, uint256 newUnlockTime);
    event ERC20LockTransferred(address indexed token, uint256 indexed lockId, address oldOwner, address newOwner);

    // Vesting Locks
    event ERC20VestingLocked(
        address indexed token,
        uint256 indexed lockId,
        address indexed owner,
        uint256 amount,
        uint256 startTime,
        uint256 initialUnlockDate,
        uint256 releaseInterval,
        uint256 releasePercent
    );
    event ERC20VestingClaimed(address indexed token, uint256 indexed lockId, address indexed owner, uint256 amount);
    event ERC20VestingCancelled(address indexed token, uint256 indexed lockId);

    // Governance + Config
    event AuthorizedCallerUpdated(address indexed oldCaller, address indexed newCaller);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
    event EmergencyWithdraw(address indexed token, address indexed to, uint256 amount);
    event Erc20LockFeeUpdated(uint256 newFee);
    event LpLockFeeUpdated(uint256 newFee);
    event MinTokenLockTimeUpdated(uint256 newTime);
    event MinLpLockTimeUpdated(uint256 newTime);

    /* ------------------------------------------------------------
     *  MODIFIERS
     * ------------------------------------------------------------ */
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier onlyAuthorized() {
        require(msg.sender == authorizedCaller, "Not authorized");
        _;
    }

    /* ------------------------------------------------------------
     *  CONSTRUCTOR
     * ------------------------------------------------------------ */
    constructor(address _treasury) {
        steakhouseTreasury = _treasury;
        owner = msg.sender;
    }

    /* ------------------------------------------------------------
     *  LP LOCKS (Graduation-only)
     * ------------------------------------------------------------ */
    function lock(address token, uint256 amount, uint256 duration, address creator)
        external
        payable
        onlyAuthorized
        nonReentrant
    {
        require(msg.value == lockFee, "Fee mismatch");
        require(lpLocks[token].amount == 0, "Already locked");
        require(duration >= minLpLockTime, "Below min lock");
        require(amount > 0, "Zero amount");

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        lpLocks[token] = Lock({amount: amount, unlockTime: block.timestamp + duration, owner: creator});

        lockedTokens.push(token);
        (bool ok,) = payable(steakhouseTreasury).call{value: msg.value}("");
        require(ok, "Fee xfer failed");

        emit Locked(token, creator, amount, block.timestamp + duration);
    }

    function extendLock(address token, uint256 extraTime) external {
        Lock storage l = lpLocks[token];
        require(msg.sender == l.owner, "Not owner");
        l.unlockTime += extraTime;
        emit LockExtended(token, l.unlockTime);
    }

    function transferLockOwnership(address token, address newOwner) external {
        Lock storage l = lpLocks[token];
        require(msg.sender == l.owner, "Not owner");
        require(newOwner != address(0), "Zero address");
        address old = l.owner;
        l.owner = newOwner;
        emit LockTransferred(token, old, newOwner);
    }

    function withdraw(address token) external nonReentrant {
        Lock storage l = lpLocks[token];
        require(msg.sender == l.owner, "Not owner");
        require(block.timestamp >= l.unlockTime, "Still locked");

        uint256 total = l.amount;
        require(total > 0, "No LP locked");

        // 75% creator withdraw, 25% permanently locked
        uint256 withdrawable = (total * 75) / 100;
        l.amount = total - withdrawable;

        IERC20(token).safeTransfer(msg.sender, withdrawable);
        emit Unlocked(token, msg.sender, withdrawable);
    }

    /* ------------------------------------------------------------
     *  GENERIC ERC20 LOCKS (Public)
     * ------------------------------------------------------------ */
    function lockERC20(address token, uint256 amount, uint256 duration) external payable nonReentrant {
        require(msg.value == erc20LockFee, "Fee mismatch");
        require(amount > 0, "Zero amount");
        require(duration >= minTokenLockTime, "Below min");
        require(token != address(0), "Zero token");

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        uint256 lockId = ++erc20LockCount[token];
        uint256 unlock = block.timestamp + duration;

        erc20Locks[token][lockId] = ERC20Lock({amount: amount, unlockTime: unlock, owner: msg.sender});
        erc20LockIdsByToken[token].push(lockId);

        (bool ok,) = payable(steakhouseTreasury).call{value: msg.value}("");
        require(ok, "Fee xfer failed");

        emit ERC20Locked(token, lockId, msg.sender, amount, unlock);
    }

    function erc20ExtendLock(address token, uint256 lockId, uint256 extraTime) external {
        ERC20Lock storage L = erc20Locks[token][lockId];
        require(L.owner == msg.sender, "Not owner");
        L.unlockTime += extraTime;
        emit ERC20LockExtended(token, lockId, L.unlockTime);
    }

    function erc20TransferLockOwnership(address token, uint256 lockId, address newOwner) external {
        ERC20Lock storage L = erc20Locks[token][lockId];
        require(L.owner == msg.sender, "Not owner");
        require(newOwner != address(0), "Zero address");
        address old = L.owner;
        L.owner = newOwner;
        emit ERC20LockTransferred(token, lockId, old, newOwner);
    }

    function erc20Withdraw(address token, uint256 lockId) external nonReentrant {
        ERC20Lock storage L = erc20Locks[token][lockId];
        require(L.owner == msg.sender, "Not owner");
        require(block.timestamp >= L.unlockTime, "Still locked");

        uint256 amt = L.amount;
        require(amt > 0, "Nothing locked");
        L.amount = 0;

        IERC20(token).safeTransfer(msg.sender, amt);
        emit ERC20Unlocked(token, lockId, msg.sender, amt);
    }

    /* ------------------------------------------------------------
     *  ERC20 VESTING LOCKS
     * ------------------------------------------------------------ */
    function lockERC20Vesting(
        address token,
        uint256 amount,
        uint256 startTime,
        uint256 initialUnlockDate,
        uint256 releaseInterval,
        uint256 releasePercent
    ) external payable nonReentrant {
        require(msg.value == erc20LockFee, "Fee mismatch");
        require(amount > 0, "Zero amount");
        require(releasePercent > 0 && releasePercent <= 100, "Bad percent");
        require(releaseInterval >= 1 days, "Too frequent");
        require(initialUnlockDate >= startTime, "Unlock < start");

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        uint256 lockId = ++vestingLockCount[token];
        vestingLocks[token][lockId] = ERC20VestingLock({
            amount: amount,
            startTime: startTime,
            initialUnlockDate: initialUnlockDate,
            releaseInterval: releaseInterval,
            releasePercent: releasePercent,
            amountWithdrawn: 0,
            owner: msg.sender,
            active: true
        });
        vestingLockIdsByToken[token].push(lockId);

        (bool ok,) = payable(steakhouseTreasury).call{value: msg.value}("");
        require(ok, "Fee xfer failed");

        emit ERC20VestingLocked(
            token, lockId, msg.sender, amount, startTime, initialUnlockDate, releaseInterval, releasePercent
        );
    }

    function getReleasableAmount(address token, uint256 lockId) public view returns (uint256) {
        ERC20VestingLock memory v = vestingLocks[token][lockId];
        if (!v.active || block.timestamp < v.initialUnlockDate) return 0;

        uint256 elapsed = block.timestamp - v.initialUnlockDate;
        uint256 periods = elapsed / v.releaseInterval;
        uint256 totalPercent = periods * v.releasePercent;
        if (totalPercent > 100) totalPercent = 100;

        uint256 unlocked = (v.amount * totalPercent) / 100;
        if (unlocked <= v.amountWithdrawn) return 0;
        return unlocked - v.amountWithdrawn;
    }

    function claimVested(address token, uint256 lockId) external nonReentrant {
        ERC20VestingLock storage v = vestingLocks[token][lockId];
        require(v.owner == msg.sender, "Not owner");
        require(v.active, "Inactive");

        uint256 claimable = getReleasableAmount(token, lockId);
        require(claimable > 0, "Nothing to claim");

        v.amountWithdrawn += claimable;
        IERC20(token).safeTransfer(msg.sender, claimable);
        emit ERC20VestingClaimed(token, lockId, msg.sender, claimable);

        if (v.amountWithdrawn >= v.amount) {
            v.active = false;
            emit ERC20VestingCancelled(token, lockId);
        }
    }

    /* ------------------------------------------------------------
     *  VIEWS
     * ------------------------------------------------------------ */
    function getLockInfo(address token) external view returns (uint256 amount, uint256 unlockTime, address lockOwner) {
        Lock storage l = lpLocks[token];
        return (l.amount, l.unlockTime, l.owner);
    }

    function getAllLockedTokens() external view returns (address[] memory) {
        return lockedTokens;
    }

    function getErc20Lock(address token, uint256 lockId)
        external
        view
        returns (uint256 amount, uint256 unlockTime, address lockOwner)
    {
        ERC20Lock storage L = erc20Locks[token][lockId];
        return (L.amount, L.unlockTime, L.owner);
    }

    function getErc20LockIds(address token) external view returns (uint256[] memory) {
        return erc20LockIdsByToken[token];
    }

    function getVestingLock(address token, uint256 lockId)
        external
        view
        returns (
            uint256 amount,
            uint256 startTime,
            uint256 initialUnlockDate,
            uint256 releaseInterval,
            uint256 releasePercent,
            uint256 withdrawn,
            address lockOwner,
            bool active
        )
    {
        ERC20VestingLock memory v = vestingLocks[token][lockId];
        return (
            v.amount,
            v.startTime,
            v.initialUnlockDate,
            v.releaseInterval,
            v.releasePercent,
            v.amountWithdrawn,
            v.owner,
            v.active
        );
    }

    function getAllLockInfo()
        external
        view
        returns (address[] memory tokens, uint256[] memory amounts, uint256[] memory unlocks, address[] memory owners)
    {
        uint256 len = lockedTokens.length;
        tokens = new address[](len);
        amounts = new uint256[](len);
        unlocks = new uint256[](len);
        owners = new address[](len);

        for (uint256 i = 0; i < len; i++) {
            address token = lockedTokens[i];
            Lock storage l = lpLocks[token];
            tokens[i] = token;
            amounts[i] = l.amount;
            unlocks[i] = l.unlockTime;
            owners[i] = l.owner;
        }
    }

    /* ------------------------------------------------------------
     *  ADMIN CONFIG
     * ------------------------------------------------------------ */
    function updateAuthorizedCaller(address _caller)
        external
        onlyOwner
        timelocked(keccak256("UPDATE_AUTHORIZED_CALLER"))
    {
        address old = authorizedCaller;
        authorizedCaller = _caller;
        emit AuthorizedCallerUpdated(old, _caller);
    }

    function transferOwnership(address newOwner) external onlyOwner timelocked(keccak256("TRANSFER_OWNERSHIP")) {
        require(newOwner != address(0), "Zero address");
        address old = owner;
        owner = newOwner;
        emit OwnershipTransferred(old, newOwner);
    }

    function updateLpLockFee(uint256 newFee) external onlyOwner timelocked(keccak256("UPDATE_LP_LOCK_FEE")) {
        require(newFee <= 0.1 ether, "Too high");
        lockFee = newFee;
        emit LpLockFeeUpdated(newFee);
    }

    function updateErc20LockFee(uint256 newFee) external onlyOwner timelocked(keccak256("UPDATE_ERC20_LOCK_FEE")) {
        require(newFee <= 0.1 ether, "Too high");
        erc20LockFee = newFee;
        emit Erc20LockFeeUpdated(newFee);
    }

    function updateMinLpLockTime(uint256 newTime) external onlyOwner timelocked(keccak256("UPDATE_MIN_LP_LOCK_TIME")) {
        require(newTime > 0, "Invalid time");
        minLpLockTime = newTime;
        emit MinLpLockTimeUpdated(newTime);
    }

    function updateMinTokenLockTime(uint256 newTime)
        external
        onlyOwner
        timelocked(keccak256("UPDATE_MIN_TOKEN_LOCK_TIME"))
    {
        require(newTime > 0, "Invalid time");
        minTokenLockTime = newTime;
        emit MinTokenLockTimeUpdated(newTime);
    }

    function getConfig() external view returns (address _treasury, address _authorizedCaller, address _owner) {
        return (steakhouseTreasury, authorizedCaller, owner);
    }

    receive() external payable {}
}
