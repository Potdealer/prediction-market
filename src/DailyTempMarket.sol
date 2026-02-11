// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title DailyTempMarket
 * @notice Daily over/under prediction market for garden temperature
 * @dev "Will today's 18:00 UTC temp be HIGHER than yesterday's?"
 *
 * Built by potdealer x Ollie for Netclawd's SensorNet
 *
 * ============ TRUST MODEL ============
 * This contract uses a TRUSTED KEEPER model for settlement.
 * The keeper reads temperature data from Net Protocol (where SensorNet
 * posts readings) off-chain and submits it to settle().
 *
 * The keeper has full authority to determine the temperature value.
 * This is NOT a trustless oracle system. Users must trust the keeper
 * to submit accurate temperature readings.
 *
 * Why? SensorNet stores readings as Net Protocol messages, not as
 * direct contract storage. There's no on-chain getTemperature() to call.
 * =====================================
 *
 * Autonomous cycle:
 * - Betting opens after previous settlement
 * - Betting closes 6 hours before settlement (12:00 UTC)
 * - Keeper reads temp from Net Protocol at 18:00 UTC
 * - Winners split 98% of NEW bets, 2% to house (rollover is fee-free)
 * - Ties roll over, one-sided markets refund
 * - Yesterday's reading auto-updates, cycle repeats
 *
 * Temperature format: int256 with 2 decimal places (e.g., 1210 = 12.10°C)
 * Valid range: -5000 to 6000 (-50.00°C to 60.00°C)
 */

interface ISensorNet {
    function getTemperature() external view returns (int256);
}

contract DailyTempMarket {
    // ============ State ============

    address public owner;
    address public keeper;
    address public treasury;
    ISensorNet public sensorNet;

    bool public paused;
    bool private _locked;             // Reentrancy guard
    uint256 public minBet;            // Minimum bet amount (changeable)

    int256 public yesterdayTemp;      // Previous day's reading
    uint256 public lastSettlement;    // Timestamp of last settlement
    uint256 public currentRound;      // Round number

    uint256 public higherPool;        // Total ETH bet on HIGHER
    uint256 public lowerPool;         // Total ETH bet on LOWER
    uint256 public rolloverPool;      // Carried over from ties

    mapping(uint256 => mapping(address => uint256)) public higherBets;
    mapping(uint256 => mapping(address => uint256)) public lowerBets;
    mapping(uint256 => address[]) public higherBettors;
    mapping(uint256 => address[]) public lowerBettors;

    // ============ Constants ============

    uint256 public constant BETTING_CLOSES_BEFORE = 6 hours;
    uint256 public constant SETTLEMENT_INTERVAL = 24 hours;
    uint256 public constant HOUSE_FEE_BPS = 200;  // 2% = 200 basis points
    uint256 public constant BPS_DENOMINATOR = 10000;
    uint256 public constant MAX_BETTORS_PER_SIDE = 200;  // Gas DoS protection
    int256 public constant MIN_TEMP = -5000;  // -50.00°C
    int256 public constant MAX_TEMP = 6000;   // 60.00°C

    // ============ Events ============

    event BetPlaced(
        uint256 indexed round,
        address indexed bettor,
        bool isHigher,
        uint256 amount,
        int256 baseline
    );
    event RoundSettled(
        uint256 indexed round,
        int256 todayTemp,
        int256 yesterdayTemp,
        bool higherWon,
        bool wasTie,
        uint256 totalPot,
        uint256 houseFee
    );
    event WinningsClaimed(uint256 indexed round, address indexed bettor, uint256 amount);
    event Refunded(uint256 indexed round, address indexed bettor, uint256 amount);
    event PayoutFailed(uint256 indexed round, address indexed bettor, uint256 amount);
    event Paused(bool isPaused);

    // ============ Modifiers ============

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier onlyKeeper() {
        require(msg.sender == keeper || msg.sender == owner, "Not keeper");
        _;
    }

    modifier notPaused() {
        require(!paused, "Contract paused");
        _;
    }

    modifier nonReentrant() {
        require(!_locked, "Reentrant call");
        _locked = true;
        _;
        _locked = false;
    }

    // ============ Constructor ============

    /**
     * @param _sensorNet Address of SensorNet contract on Base (for reference)
     * @param _keeper Address authorized to call settle() — TRUSTED to provide accurate temps
     * @param _treasury Address to receive house fees
     * @param _initialTemp Yesterday's baseline temp (2 decimal places, e.g., 1210 = 12.10°C)
     */
    constructor(
        address _sensorNet,
        address _keeper,
        address _treasury,
        int256 _initialTemp
    ) {
        require(_initialTemp >= MIN_TEMP && _initialTemp <= MAX_TEMP, "Invalid initial temp");
        owner = msg.sender;
        keeper = _keeper;
        treasury = _treasury;
        sensorNet = ISensorNet(_sensorNet);
        yesterdayTemp = _initialTemp;
        lastSettlement = block.timestamp;
        currentRound = 1;
        minBet = 0.001 ether;  // Default minimum bet
    }

    // ============ Betting ============

    /**
     * @notice Bet that today's temp will be HIGHER than yesterday's
     */
    function betHigher() external payable notPaused {
        require(msg.value >= minBet, "Below minimum bet");
        require(bettingOpen(), "Betting closed");
        require(higherBets[currentRound][msg.sender] == 0, "Already bet HIGHER");
        require(lowerBets[currentRound][msg.sender] == 0, "Already bet LOWER");
        require(higherBettors[currentRound].length < MAX_BETTORS_PER_SIDE, "Too many bettors");

        higherBets[currentRound][msg.sender] = msg.value;
        higherBettors[currentRound].push(msg.sender);
        higherPool += msg.value;

        emit BetPlaced(currentRound, msg.sender, true, msg.value, yesterdayTemp);
    }

    /**
     * @notice Bet that today's temp will be LOWER or equal to yesterday's
     */
    function betLower() external payable notPaused {
        require(msg.value >= minBet, "Below minimum bet");
        require(bettingOpen(), "Betting closed");
        require(lowerBets[currentRound][msg.sender] == 0, "Already bet LOWER");
        require(higherBets[currentRound][msg.sender] == 0, "Already bet HIGHER");
        require(lowerBettors[currentRound].length < MAX_BETTORS_PER_SIDE, "Too many bettors");

        lowerBets[currentRound][msg.sender] = msg.value;
        lowerBettors[currentRound].push(msg.sender);
        lowerPool += msg.value;

        emit BetPlaced(currentRound, msg.sender, false, msg.value, yesterdayTemp);
    }

    /**
     * @notice Check if betting is currently open
     */
    function bettingOpen() public view returns (bool) {
        if (paused) return false;
        uint256 nextSettlement = lastSettlement + SETTLEMENT_INTERVAL;
        uint256 bettingDeadline = nextSettlement - BETTING_CLOSES_BEFORE;
        return block.timestamp < bettingDeadline;
    }

    /**
     * @notice Time until betting closes (0 if already closed)
     */
    function timeUntilBettingCloses() external view returns (uint256) {
        uint256 nextSettlement = lastSettlement + SETTLEMENT_INTERVAL;
        uint256 bettingDeadline = nextSettlement - BETTING_CLOSES_BEFORE;
        if (block.timestamp >= bettingDeadline) return 0;
        return bettingDeadline - block.timestamp;
    }

    /**
     * @notice Time until next settlement (0 if ready)
     */
    function timeUntilSettlement() external view returns (uint256) {
        uint256 nextSettlement = lastSettlement + SETTLEMENT_INTERVAL;
        if (block.timestamp >= nextSettlement) return 0;
        return nextSettlement - block.timestamp;
    }

    // ============ Settlement ============

    /**
     * @notice Settle the current round — called by keeper at 18:00 UTC daily
     * @dev Keeper reads temperature from Net Protocol off-chain and passes it here.
     *      THE KEEPER IS FULLY TRUSTED to provide the correct temperature.
     * @param todayTemp Today's temperature reading (2 decimal places)
     */
    function settle(int256 todayTemp) external onlyKeeper notPaused nonReentrant {
        uint256 nextSettlement = lastSettlement + SETTLEMENT_INTERVAL;
        require(block.timestamp >= nextSettlement, "Too early to settle");
        require(todayTemp >= MIN_TEMP && todayTemp <= MAX_TEMP, "Temperature out of bounds");

        uint256 newBets = higherPool + lowerPool;
        uint256 totalPool = newBets + rolloverPool;
        bool wasTie = (todayTemp == yesterdayTemp);
        bool higherWon = (todayTemp > yesterdayTemp);

        uint256 houseFee = 0;

        if (totalPool == 0) {
            // No bets — just advance
        } else if (higherPool == 0 || lowerPool == 0) {
            // One-sided market — refund everyone
            _refundAll();
            // Rollover stays intact for next round
        } else if (wasTie) {
            // Tie — roll over entire pot
            rolloverPool = totalPool;
        } else {
            // We have winners — take house fee on NEW BETS ONLY (not rollover)
            houseFee = (newBets * HOUSE_FEE_BPS) / BPS_DENOMINATOR;
            uint256 winnerPool = totalPool - houseFee;

            // Send house fee to treasury
            if (houseFee > 0) {
                (bool feeSuccess, ) = treasury.call{value: houseFee}("");
                require(feeSuccess, "Fee transfer failed");
            }

            // Distribute to winners
            rolloverPool = 0;
            if (higherWon) {
                _distributeWinnings(true, winnerPool);
            } else {
                _distributeWinnings(false, winnerPool);
            }
        }

        emit RoundSettled(
            currentRound,
            todayTemp,
            yesterdayTemp,
            higherWon,
            wasTie,
            totalPool,
            houseFee
        );

        // Reset for next round
        yesterdayTemp = todayTemp;
        lastSettlement = block.timestamp;
        higherPool = 0;
        lowerPool = 0;
        currentRound++;
    }

    function _distributeWinnings(bool higherWon, uint256 totalPayout) internal {
        address[] storage winners = higherWon
            ? higherBettors[currentRound]
            : lowerBettors[currentRound];
        uint256 winningPool = higherWon ? higherPool : lowerPool;

        for (uint256 i = 0; i < winners.length; i++) {
            address winner = winners[i];
            uint256 bet = higherWon
                ? higherBets[currentRound][winner]
                : lowerBets[currentRound][winner];

            uint256 payout = (bet * totalPayout) / winningPool;

            (bool success, ) = winner.call{value: payout}("");
            if (success) {
                emit WinningsClaimed(currentRound, winner, payout);
            } else {
                emit PayoutFailed(currentRound, winner, payout);
            }
        }
    }

    function _refundAll() internal {
        for (uint256 i = 0; i < higherBettors[currentRound].length; i++) {
            address bettor = higherBettors[currentRound][i];
            uint256 amount = higherBets[currentRound][bettor];
            if (amount > 0) {
                (bool success, ) = bettor.call{value: amount}("");
                if (success) {
                    emit Refunded(currentRound, bettor, amount);
                } else {
                    emit PayoutFailed(currentRound, bettor, amount);
                }
            }
        }

        for (uint256 i = 0; i < lowerBettors[currentRound].length; i++) {
            address bettor = lowerBettors[currentRound][i];
            uint256 amount = lowerBets[currentRound][bettor];
            if (amount > 0) {
                (bool success, ) = bettor.call{value: amount}("");
                if (success) {
                    emit Refunded(currentRound, bettor, amount);
                } else {
                    emit PayoutFailed(currentRound, bettor, amount);
                }
            }
        }
    }

    // ============ Views ============

    /**
     * @notice Get current market state — useful for frontends and agents
     */
    function getMarketState() external view returns (
        uint256 round,
        int256 baseline,
        uint256 higherTotal,
        uint256 lowerTotal,
        uint256 rollover,
        bool isBettingOpen,
        uint256 secondsUntilClose,
        uint256 secondsUntilSettle
    ) {
        uint256 nextSettlement = lastSettlement + SETTLEMENT_INTERVAL;
        uint256 bettingDeadline = nextSettlement - BETTING_CLOSES_BEFORE;

        return (
            currentRound,
            yesterdayTemp,
            higherPool,
            lowerPool,
            rolloverPool,
            bettingOpen(),
            block.timestamp < bettingDeadline ? bettingDeadline - block.timestamp : 0,
            block.timestamp < nextSettlement ? nextSettlement - block.timestamp : 0
        );
    }

    /**
     * @notice Get a user's bet for current round
     */
    function getMyBet(address user) external view returns (uint256 higherAmt, uint256 lowerAmt) {
        return (higherBets[currentRound][user], lowerBets[currentRound][user]);
    }

    /**
     * @notice Get bet counts for current round
     */
    function getBetCounts() external view returns (uint256 higherCount, uint256 lowerCount) {
        return (higherBettors[currentRound].length, lowerBettors[currentRound].length);
    }

    // ============ Admin ============

    function pause() external onlyOwner {
        paused = true;
        emit Paused(true);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Paused(false);
    }

    function setKeeper(address _keeper) external onlyOwner {
        keeper = _keeper;
    }

    function setTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;
    }

    function setSensorNet(address _sensorNet) external onlyOwner {
        sensorNet = ISensorNet(_sensorNet);
    }

    function setMinBet(uint256 _minBet) external onlyOwner {
        minBet = _minBet;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid owner");
        owner = newOwner;
    }

    /**
     * @notice Emergency rescue stuck funds (only if paused)
     * @dev Can be used to recover failed payouts or accidental transfers
     */
    function rescue(address to, uint256 amount) external onlyOwner {
        require(paused, "Must pause first");
        require(amount <= address(this).balance, "Insufficient balance");
        (bool success, ) = to.call{value: amount}("");
        require(success, "Rescue failed");
    }

    /**
     * @notice Reject direct ETH transfers to prevent accounting issues
     */
    receive() external payable {
        revert("Use betHigher() or betLower()");
    }
}
