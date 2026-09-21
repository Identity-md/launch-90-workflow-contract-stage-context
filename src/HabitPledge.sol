// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Custodies equal weekly PLDG slices and settles them according to weekly check-ins.
contract HabitPledge {
    uint256 public constant WEEK = 7 days;
    uint8 public constant MAX_WEEKS = 52;
    IERC20 public immutable token;
    uint256 public nextPledgeId;

    struct Commitment {
        address pledger;
        address beneficiary;
        uint64 startTime;
        uint8 weeksCount;
        uint8 checkedCount;
        bool settled;
        uint256 stake;
        uint256 checkedBitmap;
        string goal;
    }

    mapping(uint256 pledgeId => Commitment) private commitments;
    bool private entered;

    event PledgeCreated(
        uint256 indexed pledgeId,
        address indexed pledger,
        address indexed beneficiary,
        uint256 stake,
        uint8 weeksCount,
        uint64 startTime,
        string goal
    );
    event CheckedIn(uint256 indexed pledgeId, uint8 indexed week, uint64 timestamp);
    event PledgeSettled(
        uint256 indexed pledgeId, uint256 returnedToPledger, uint256 forfeitedToBeneficiary
    );

    error Reentrancy();
    error InvalidToken();
    error InvalidBeneficiary();
    error InvalidWeeks();
    error InvalidStake();
    error EmptyGoal();
    error TransferFailed();
    error UnknownPledge();
    error Unauthorized();
    error PledgeEnded();
    error PledgeActive();
    error AlreadyCheckedIn();
    error AlreadySettled();

    modifier nonReentrant() {
        if (entered) revert Reentrancy();
        entered = true;
        _;
        entered = false;
    }

    constructor(address tokenAddress) {
        if (tokenAddress == address(0) || tokenAddress.code.length == 0) revert InvalidToken();
        token = IERC20(tokenAddress);
    }

    function createPledge(
        string calldata goal,
        uint8 weeksCount,
        address beneficiary,
        uint256 stake
    ) external nonReentrant returns (uint256 pledgeId) {
        if (beneficiary == address(0) || beneficiary == msg.sender) {
            revert InvalidBeneficiary();
        }
        if (weeksCount == 0 || weeksCount > MAX_WEEKS) revert InvalidWeeks();
        if (stake == 0 || stake % weeksCount != 0) revert InvalidStake();
        if (bytes(goal).length == 0) revert EmptyGoal();

        pledgeId = nextPledgeId++;
        uint64 startTime = uint64(block.timestamp);
        commitments[pledgeId] = Commitment({
            pledger: msg.sender,
            beneficiary: beneficiary,
            startTime: startTime,
            weeksCount: weeksCount,
            checkedCount: 0,
            settled: false,
            stake: stake,
            checkedBitmap: 0,
            goal: goal
        });

        _safeTransferFrom(msg.sender, address(this), stake);
        emit PledgeCreated(pledgeId, msg.sender, beneficiary, stake, weeksCount, startTime, goal);
    }

    function checkIn(uint256 pledgeId) external nonReentrant {
        Commitment storage commitment = _get(pledgeId);
        if (msg.sender != commitment.pledger) revert Unauthorized();
        uint256 elapsed = block.timestamp - commitment.startTime;
        uint256 week = elapsed / WEEK;
        if (week >= commitment.weeksCount) revert PledgeEnded();
        uint256 mask = uint256(1) << week;
        if (commitment.checkedBitmap & mask != 0) revert AlreadyCheckedIn();

        commitment.checkedBitmap |= mask;
        ++commitment.checkedCount;
        emit CheckedIn(pledgeId, uint8(week), uint64(block.timestamp));
    }

    /// @notice Settles after the final window. Anyone may trigger deterministic settlement.
    function withdraw(uint256 pledgeId) external nonReentrant {
        Commitment storage commitment = _get(pledgeId);
        if (commitment.settled) revert AlreadySettled();
        if (block.timestamp < endTime(pledgeId)) revert PledgeActive();

        commitment.settled = true;
        uint256 slice = commitment.stake / commitment.weeksCount;
        uint256 returned = slice * commitment.checkedCount;
        uint256 forfeited = commitment.stake - returned;

        if (returned != 0) _safeTransfer(commitment.pledger, returned);
        if (forfeited != 0) _safeTransfer(commitment.beneficiary, forfeited);
        emit PledgeSettled(pledgeId, returned, forfeited);
    }

    function getPledge(uint256 pledgeId) external view returns (Commitment memory) {
        return _get(pledgeId);
    }

    function endTime(uint256 pledgeId) public view returns (uint256) {
        Commitment storage commitment = _get(pledgeId);
        return uint256(commitment.startTime) + uint256(commitment.weeksCount) * WEEK;
    }

    function currentWeek(uint256 pledgeId) external view returns (uint8 week, bool active) {
        Commitment storage commitment = _get(pledgeId);
        uint256 elapsed = block.timestamp - commitment.startTime;
        uint256 index = elapsed / WEEK;
        if (index >= commitment.weeksCount) return (commitment.weeksCount, false);
        return (uint8(index), true);
    }

    function _get(uint256 pledgeId) private view returns (Commitment storage commitment) {
        commitment = commitments[pledgeId];
        if (commitment.pledger == address(0)) revert UnknownPledge();
    }

    function _safeTransfer(address to, uint256 amount) private {
        (bool ok, bytes memory result) =
            address(token).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!ok || (result.length != 0 && !abi.decode(result, (bool)))) revert TransferFailed();
    }

    function _safeTransferFrom(address from, address to, uint256 amount) private {
        (bool ok, bytes memory result) =
            address(token).call(abi.encodeCall(IERC20.transferFrom, (from, to, amount)));
        if (!ok || (result.length != 0 && !abi.decode(result, (bool)))) revert TransferFailed();
    }
}
