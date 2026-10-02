// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title Agent — a per-owner account that Tock drives on a schedule
/// @notice Every job runs *from* its owner's Agent, never from Tock itself. That keeps owners
///         isolated from one another and from the gas balances Tock holds: a job can only move
///         what its own Agent holds or is allowed to spend.
contract Agent {
    address public immutable TOCK;
    address public immutable OWNER;

    error NotAuthorized();

    constructor(address owner_) {
        TOCK = msg.sender;
        OWNER = owner_;
    }

    /// @notice Make a call from this account. Tock uses it for scheduled runs; the owner can use
    ///         it at any time, which is also how funds are taken back out.
    /// @return ok whether the call succeeded; a failure is reported, not bubbled up
    function exec(address target, uint256 value, bytes calldata data) external returns (bool ok) {
        if (msg.sender != TOCK && msg.sender != OWNER) revert NotAuthorized();
        (ok,) = target.call{value: value}(data);
    }

    /// @notice The scheduled path. Tock forwards exactly the gas the job's owner asked for, so
    ///         the call gets its full allowance however large it is.
    function run(address target, uint256 value, bytes calldata data, uint256 gas) external returns (bool ok) {
        if (msg.sender != TOCK) revert NotAuthorized();
        (ok,) = target.call{value: value, gas: gas}(data);
    }

    /// @dev On Arc the native balance *is* USDC, so funding an Agent is a plain transfer.
    receive() external payable {}
}

/// @title Tock — scheduled transactions for Arc, paid in USDC
/// @notice An owner registers a job (a call, an interval, a fee cap) and prepays a gas balance.
///         Anyone may run a job once it is due. The executor is paid back the gas it used at
///         the block base fee, plus a tip, out of the owner's balance.
///
///         Everything here is denominated in native USDC (18 decimals). On Arc that is the gas
///         token, so `gasUsed * block.basefee` is already the executor's cost in dollars: no
///         oracle, no keeper token, and — because deposits are `msg.value` — no ERC-20 calls.
contract Tock {
    // ───────────────────────────── types ─────────────────────────────

    struct Job {
        address owner;
        address target;
        uint40 nextRun;
        uint32 interval; // seconds between runs
        uint32 gasLimit; // gas forwarded to the target call
        uint32 runs; // runs executed, successful or not
        uint32 maxRuns; // stop after this many runs; 0 means never
        uint8 failures; // consecutive failed runs
        bool active;
        uint128 value; // native USDC sent with each call, from the owner's Agent
        uint128 maxFee; // most an executor may be paid for one run
        uint128 tip; // executor incentive on top of the gas refund
        bytes data;
        string name;
    }

    /// @notice What an owner supplies to schedule a job.
    struct JobSpec {
        address target; // contract or account the owner's Agent will call
        bytes data; // calldata for the call; empty for a plain USDC payment
        uint128 value; // native USDC sent with each call, taken from the Agent's balance
        uint32 interval; // seconds between runs
        uint40 firstRun; // when the first run is due; 0 for now
        uint32 gasLimit; // gas forwarded to the call; the owner never pays for more
        uint128 maxFee; // cap on what one run can cost the owner (gas refund + tip)
        uint128 tip; // what the executor earns on top of its gas
        uint32 maxRuns; // stop after this many runs; 0 keeps it going until cancelled
        string name;
    }

    // ─────────────────────────── constants ───────────────────────────

    uint32 public constant MIN_INTERVAL = 1 minutes;
    uint32 public constant MIN_GAS_LIMIT = 30_000;
    uint32 public constant MAX_GAS_LIMIT = 5_000_000;
    /// @notice A job that fails this many times in a row pauses itself, so a broken target or an
    ///         empty Agent cannot quietly drain its owner's gas balance.
    uint8 public constant MAX_FAILURES = 3;

    /// @notice Longest calldata a job may carry. Reading it from storage costs gas in proportion,
    ///         and a bound on that cost is what lets a run guarantee the call its gas.
    uint256 public constant MAX_DATA_LENGTH = 1024;

    /// @dev Gas the in-call measurement cannot see, calibrated against real transactions on a
    ///      mainnet fork. RUN_OVERHEAD covers bookkeeping and the payout that happen after the
    ///      measurement. TX_OVERHEAD covers the 21000 intrinsic gas, calldata and first-touch
    ///      costs, and is refunded once per transaction however many jobs it runs.
    uint256 internal constant RUN_OVERHEAD = 20_000;
    uint256 internal constant TX_OVERHEAD = 17_000;
    /// @dev Gas the Agent may need around the target call: its own dispatch, a cold account, a
    ///      value transfer and, at worst, creating the recipient account.
    uint256 internal constant AGENT_OVERHEAD = 45_000;
    /// @dev Gas `_run` needs after the call returns: failure bookkeeping, the fee and the payout.
    uint256 internal constant POST_RUN_RESERVE = 60_000;
    /// @dev Upper bounds used only for `worstCaseGas`: the transaction's intrinsic gas, Tock's
    ///      work before the call, and the cost of loading and forwarding each 32-byte word of
    ///      the job's calldata.
    uint256 internal constant TX_INTRINSIC_GAS = 23_000;
    uint256 internal constant PRE_CALL_GAS = 30_000;
    uint256 internal constant GAS_PER_DATA_WORD = 2_500;

    // ──────────────────────────── storage ────────────────────────────

    Job[] internal _jobs;
    /// @notice Prepaid gas balance per owner, in native USDC. Shared by all of that owner's jobs.
    mapping(address owner => uint256) public balanceOf;
    mapping(address owner => uint256[]) internal _jobsOf;
    mapping(address owner => address) public agentOf;

    bool private transient _locked;
    bool private transient _txOverheadRefunded;

    // ──────────────────────────── events ─────────────────────────────

    event AgentCreated(address indexed owner, address agent);
    event JobCreated(uint256 indexed jobId, address indexed owner, address indexed target, uint32 interval, string name);
    event JobRan(
        uint256 indexed jobId, address indexed executor, bool success, uint256 fee, uint40 nextRun, uint32 runs
    );
    event JobPaused(uint256 indexed jobId, bool byFailures);
    event JobResumed(uint256 indexed jobId, uint40 nextRun);
    event JobCancelled(uint256 indexed jobId);
    event Deposited(address indexed owner, address indexed from, uint256 amount);
    event Withdrawn(address indexed owner, address indexed to, uint256 amount);

    // ──────────────────────────── errors ─────────────────────────────

    error NotOwner();
    error NotAuthorized();
    error BadParams();
    error JobInactive();
    error NotDue(uint40 nextRun);
    error Underfunded();
    error FeeCapTooLow();
    error InsufficientGas();
    error TransferFailed();
    error Reentrancy();

    modifier nonReentrant() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    // ───────────────────────────── owners ────────────────────────────

    /// @notice Add to your gas balance. Any `msg.value` sent with `createJob` is credited too.
    function deposit() external payable nonReentrant {
        _credit(msg.sender);
    }

    /// @notice Top up someone else's gas balance.
    function depositFor(address owner) external payable nonReentrant {
        if (owner == address(0)) revert BadParams();
        _credit(owner);
    }

    function withdraw(uint256 amount, address payable to) external nonReentrant {
        balanceOf[msg.sender] -= amount; // reverts on overdraw
        _pay(to, amount);
        emit Withdrawn(msg.sender, to, amount);
    }

    /// @notice Schedule a call. The first run is due at `firstRun` (or now, if that has passed).
    ///         Any `msg.value` is added to the caller's gas balance.
    function createJob(JobSpec calldata spec) external payable nonReentrant returns (uint256 jobId) {
        if (spec.target == address(0) || spec.target == address(this)) revert BadParams();
        if (spec.interval < MIN_INTERVAL || spec.gasLimit < MIN_GAS_LIMIT || spec.gasLimit > MAX_GAS_LIMIT) {
            revert BadParams();
        }
        if (spec.tip > spec.maxFee || spec.maxFee == 0 || bytes(spec.name).length > 64) revert BadParams();
        if (spec.data.length > MAX_DATA_LENGTH) revert BadParams();

        if (agentOf[msg.sender] == address(0)) {
            address agent = address(new Agent{salt: bytes32(uint256(uint160(msg.sender)))}(msg.sender));
            agentOf[msg.sender] = agent;
            emit AgentCreated(msg.sender, agent);
        }
        if (msg.value != 0) _credit(msg.sender);

        jobId = _jobs.length;
        Job storage j = _jobs.push();
        j.owner = msg.sender;
        j.target = spec.target;
        // forge-lint: disable-next-line(unsafe-typecast)
        j.nextRun = spec.firstRun > block.timestamp ? spec.firstRun : uint40(block.timestamp);
        j.interval = spec.interval;
        j.gasLimit = spec.gasLimit;
        j.maxRuns = spec.maxRuns;
        j.active = true;
        j.value = spec.value;
        j.maxFee = spec.maxFee;
        j.tip = spec.tip;
        j.data = spec.data;
        j.name = spec.name;
        _jobsOf[msg.sender].push(jobId);
        emit JobCreated(jobId, msg.sender, spec.target, spec.interval, spec.name);
    }

    function pause(uint256 jobId) external nonReentrant {
        Job storage j = _own(jobId);
        if (!j.active) revert JobInactive();
        j.active = false;
        emit JobPaused(jobId, false);
    }

    /// @notice Resume a paused job. Its next run is due one interval from now, and the failure
    ///         count starts over.
    function resume(uint256 jobId) external nonReentrant {
        Job storage j = _own(jobId);
        if (j.active || j.interval == 0) revert BadParams();
        j.active = true;
        j.failures = 0;
        // forge-lint: disable-next-line(unsafe-typecast)
        j.nextRun = uint40(block.timestamp + j.interval); // safe: fits 40 bits
        emit JobResumed(jobId, j.nextRun);
    }

    /// @notice End a job for good.
    function cancel(uint256 jobId) external nonReentrant {
        Job storage j = _own(jobId);
        j.active = false;
        j.interval = 0; // marks it as not resumable
        emit JobCancelled(jobId);
    }

    // ─────────────────────────── executors ───────────────────────────

    /// @notice Run a due job. Open to anyone. The caller is paid its gas plus the tip whether
    ///         or not the job's own call succeeds — it did the work either way.
    function run(uint256 jobId) external nonReentrant {
        _run(jobId, msg.sender, gasleft());
    }

    /// @notice Run several jobs in one transaction. Each is attempted in isolation: one that is
    ///         not due, is underfunded, or cannot be paid for is skipped, not fatal.
    /// @return ran number of jobs executed
    function runBatch(uint256[] calldata jobIds) external nonReentrant returns (uint256 ran) {
        for (uint256 i; i < jobIds.length; ++i) {
            try this.runFor(jobIds[i], msg.sender) {
                ++ran;
            } catch (bytes memory reason) {
                // Running short of gas must fail the batch, or a gas estimate could settle on a
                // limit that silently skips jobs.
                if (bytes4(reason) == InsufficientGas.selector) revert InsufficientGas();
            }
        }
    }

    /// @dev Batch helper. External only so that one job can revert on its own.
    function runFor(uint256 jobId, address executor) external {
        if (msg.sender != address(this)) revert NotAuthorized();
        _run(jobId, executor, gasleft());
    }

    // ───────────────────────────── views ─────────────────────────────

    function jobCount() external view returns (uint256) {
        return _jobs.length;
    }

    function getJob(uint256 jobId) external view returns (Job memory) {
        return _jobs[jobId];
    }

    function jobsOf(address owner) external view returns (uint256[] memory) {
        return _jobsOf[owner];
    }

    /// @notice The address an owner's Agent has, or will have once their first job creates it.
    function predictAgent(address owner) external view returns (address) {
        bytes32 salt = bytes32(uint256(uint160(owner)));
        bytes32 initHash = keccak256(abi.encodePacked(type(Agent).creationCode, abi.encode(owner)));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initHash)))));
    }

    /// @notice A gas limit that is always enough to run this job once in its own transaction,
    ///         and an upper bound on what that transaction can use, even if the call burns its
    ///         entire gas limit. Executors should send this much; the fee cap is judged against it.
    function worstCaseGas(uint256 jobId) public view returns (uint256) {
        Job storage j = _jobs[jobId];
        uint256 gasLimit = j.gasLimit;
        uint256 agentGas = gasLimit + gasLimit / 63 + AGENT_OVERHEAD;
        return TX_INTRINSIC_GAS + PRE_CALL_GAS + GAS_PER_DATA_WORD * ((j.data.length + 31) / 32) + agentGas
            + agentGas / 63 + POST_RUN_RESERVE;
    }

    /// @notice Jobs in `[from, from + count)` that can be run right now: active, due, funded, and
    ///         with a fee cap that covers the executor even if the call burns its whole gas
    ///         limit. Lets an executor work with no indexer.
    /// @param baseFee the base fee to judge fee caps against. It is an argument because a plain
    ///        `eth_call` on Arc reports `block.basefee` as zero; pass the latest block's value.
    function runnable(uint256 from, uint256 count, uint256 baseFee) external view returns (uint256[] memory ids) {
        uint256 end = from + count;
        if (end > _jobs.length) end = _jobs.length;
        if (from >= end) return ids;
        ids = new uint256[](end - from);
        uint256 n;
        for (uint256 i = from; i < end; ++i) {
            Job storage j = _jobs[i];
            if (!j.active || block.timestamp < j.nextRun) continue;
            if (balanceOf[j.owner] < j.maxFee || j.maxFee < worstCaseGas(i) * baseFee) continue;
            ids[n++] = i;
        }
        assembly {
            mstore(ids, n)
        }
    }

    // ─────────────────────────── internals ───────────────────────────

    function _run(uint256 jobId, address executor, uint256 gasStart) internal {
        Job storage j = _jobs[jobId];
        if (!j.active) revert JobInactive();
        if (block.timestamp < j.nextRun) revert NotDue(j.nextRun);
        uint256 maxFee = j.maxFee;
        address owner = j.owner;
        if (balanceOf[owner] < maxFee) revert Underfunded();
        // An executor is never left out of pocket: if the cap cannot cover a run that burns its
        // whole gas limit at today's base fee, the job waits for fees to come down.
        if (maxFee < worstCaseGas(jobId) * block.basefee) revert FeeCapTooLow();

        // Schedule first, call second. A run that lands late does not trigger a burst of
        // catch-up runs: the next one is always at least a full interval after this one.
        uint256 next = uint256(j.nextRun) + j.interval;
        if (next <= block.timestamp) next = block.timestamp + j.interval;
        // forge-lint: disable-next-line(unsafe-typecast)
        j.nextRun = uint40(next); // safe: a timestamp plus a uint32 interval fits 40 bits
        uint32 runs = ++j.runs;

        bool ok = _call(j, owner);

        if (ok) {
            j.failures = 0;
        } else if (++j.failures >= MAX_FAILURES) {
            j.active = false;
            emit JobPaused(jobId, true);
        }
        if (j.maxRuns != 0 && runs >= j.maxRuns) {
            j.active = false;
            j.interval = 0; // finished: not resumable
            emit JobCancelled(jobId);
        }

        uint256 overhead = RUN_OVERHEAD;
        if (!_txOverheadRefunded) {
            _txOverheadRefunded = true;
            overhead += TX_OVERHEAD;
        }
        // Refund at block.basefee, not tx.gasprice: an executor that overbids pays the
        // difference itself and cannot inflate what the owner is charged.
        uint256 fee = (gasStart - gasleft() + overhead) * block.basefee + j.tip;
        if (fee > maxFee) fee = maxFee;
        balanceOf[owner] -= fee;
        emit JobRan(jobId, executor, ok, fee, j.nextRun, runs);
        _pay(executor, fee);
    }

    /// @dev Makes the job's call through its owner's Agent. Everything the call needs is loaded
    ///      first, and the gas check comes last, immediately before the call: the call then gets
    ///      the gas its owner asked for or the run reverts. Without that an executor could starve
    ///      a job on purpose and still collect the fee.
    function _call(Job storage j, address owner) internal returns (bool ok) {
        address agent = agentOf[owner];
        address target = j.target;
        uint256 value = j.value;
        uint256 gasLimit = j.gasLimit;
        bytes memory data = j.data;

        // The Agent keeps 1/64 of what it is given, so it is given 1/63 more than it must forward.
        uint256 agentGas = gasLimit + gasLimit / 63 + AGENT_OVERHEAD;
        if (gasleft() < agentGas + agentGas / 63 + POST_RUN_RESERVE) revert InsufficientGas();
        try Agent(payable(agent)).run{gas: agentGas}(target, value, data, gasLimit) returns (bool success) {
            ok = success;
        } catch {}
    }

    function _own(uint256 jobId) internal view returns (Job storage j) {
        j = _jobs[jobId];
        if (msg.sender != j.owner) revert NotOwner();
    }

    function _credit(address owner) internal {
        balanceOf[owner] += msg.value;
        emit Deposited(owner, msg.sender, msg.value);
    }

    /// @dev A native transfer on Arc can revert even with funds available (a blocklisted
    ///      recipient, for one), so the result is checked rather than assumed.
    function _pay(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
