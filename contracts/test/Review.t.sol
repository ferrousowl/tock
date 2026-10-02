// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {Tock, Agent} from "../src/Tock.sol";

/// @dev arc-forge returns the five-field Gas struct; forge-std's newer definition has more.
interface VmGas {
    struct Gas5 {
        uint64 gasLimit;
        uint64 gasTotalUsed;
        uint64 gasMemoryUsed;
        int64 gasRefunded;
        uint64 gasRemaining;
    }

    function lastCallGas() external view returns (Gas5 memory);
}

interface IUSDC {
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @dev A target that really needs `need` gas to finish (think: a rebalance, a batch payout).
contract GasNeedy {
    uint256 public done;

    function work(uint256 need, bytes calldata) external {
        uint256 g = gasleft();
        while (g - gasleft() < need) {}
        ++done;
    }
}

/// @dev Burns everything it is given; records nothing.
contract Burner {
    fallback() external payable {
        while (gasleft() > 500) {}
    }
}

/// @dev Cheap until its owner flips a switch, then burns everything it is given.
contract FlipBurner {
    bool public on;

    function set(bool v) external {
        on = v;
    }

    fallback() external payable {
        if (on) while (gasleft() > 500) {}
    }
}

/// @dev Records the gas it was actually handed.
contract GasProbe {
    uint256 public got;

    fallback() external payable {
        got = gasleft();
    }
}

/// @dev Returns a large blob.
contract Bomb {
    fallback() external payable {
        assembly {
            return(0, 200000)
        }
    }
}

/// Tests from an adversarial review of Tock. F1–F4 were real findings; each is fixed in the
/// contract and its test now asserts the corrected behaviour. The `sound` tests record
/// properties the review probed and found to hold.
///
/// Do NOT add --isolate: arc-forge executes isolated calls with block.basefee == 0, so every
/// fee is just the tip. Cold storage is reproduced with vm.cool instead.
contract ReviewTest is Test {
    address constant USDC = 0x3600000000000000000000000000000000000000;
    address constant MULTICALL3_FROM = 0x522fAf9A91c41c443c66765030741e4AaCe147D0;
    address constant MEMO = 0x5294E9927c3306DcBaDb03fe70b92e01cCede505;
    address constant CALL_FROM = 0x1800000000000000000000000000000000000003;
    address constant NATIVE_COIN = 0x1800000000000000000000000000000000000000;

    Tock tock;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address payee = makeAddr("payee");
    address keeper = makeAddr("keeper");
    address mallory = makeAddr("mallory");

    uint32 constant HOUR = 1 hours;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ARC_RPC", string("https://rpc.mainnet.arc.io")));
        tock = new Tock();
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
        vm.deal(keeper, 1000 ether);
        vm.deal(mallory, 1000 ether);
        vm.fee(20 gwei);
        vm.txGasPrice(20 gwei);
    }

    function _runWithGas(uint256 id, uint256 gas_) internal returns (bool ok) {
        vm.cool(address(tock));
        vm.prank(keeper, keeper);
        (ok,) = address(tock).call{gas: gas_}(abi.encodeCall(Tock.run, (id)));
    }

    /// @dev What eth_estimateGas does: the smallest gas limit at which the transaction succeeds.
    function _estimate(uint256 id) internal returns (uint256 lo) {
        lo = 30_000;
        uint256 hi = 12_000_000;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            bool ok = _runWithGas(id, mid);
            vm.revertToState(snap);
            if (ok) hi = mid;
            else lo = mid + 1;
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // F1 (fixed): the InsufficientGas guard used to run *before* `j.data` was read from storage
    //     and copied, so with a few KB of calldata it passed while the Agent was handed far less
    //     than its gas: the job failed, the executor was paid, three of those paused the job.
    //     Calldata is now capped at 1 KB and the guard runs immediately before the call.
    // ─────────────────────────────────────────────────────────────────────────────
    function test_F1_callCannotBeStarvedWithLargeCalldata() public {
        GasNeedy target = new GasNeedy();
        bytes memory pad = new bytes(800); // with the selector and ABI framing this is close to the cap
        for (uint256 i; i < pad.length; ++i) pad[i] = 0x11;
        // The owner leaves 10% headroom: the call needs 900k and the job allows 1M.
        Tock.JobSpec memory s = Tock.JobSpec({
            target: address(target),
            data: abi.encodeCall(GasNeedy.work, (900_000, pad)),
            value: 0,
            interval: HOUR,
            firstRun: 0,
            gasLimit: 1_000_000,
            maxFee: 1 ether,
            tip: 0.001 ether,
            maxRuns: 0,
            name: "needs 900k"
        });
        assertLe(s.data.length, tock.MAX_DATA_LENGTH());
        vm.prank(alice);
        uint256 id = tock.createJob{value: 10 ether}(s);

        // The executor (or simply eth_estimateGas) picks the smallest gas limit that does not revert.
        uint256 g = _estimate(id);
        emit log_named_uint("minimal non-reverting gas for run()", g);
        assertTrue(_runWithGas(id, g), "run() succeeds");
        assertEq(target.done(), 1, "and at that gas the call really ran");
        assertEq(tock.getJob(id).failures, 0);
        assertLe(g, tock.worstCaseGas(id), "worstCaseGas is enough to run it");
    }

    function test_F1_calldataAboveTheCapIsRejected() public {
        Tock.JobSpec memory s = Tock.JobSpec(payee, new bytes(1025), 0, HOUR, 0, 100_000, 1 ether, 0, 0, "big");
        vm.prank(alice);
        vm.expectRevert(Tock.BadParams.selector);
        tock.createJob(s);
    }

    /// The target is handed its full gas limit whatever the calldata size, even when the
    /// executor supplies the minimal non-reverting gas.
    function test_F1b_targetGetsItsGasAtEveryCalldataSize() public {
        uint256[4] memory sizes = [uint256(0), 256, 512, 1024];
        for (uint256 i; i < sizes.length; ++i) {
            GasProbe p = new GasProbe();
            Tock.JobSpec memory s =
                Tock.JobSpec(address(p), new bytes(sizes[i]), 0, HOUR, 0, 1_000_000, 1 ether, 0, 0, "probe");
            vm.prank(alice);
            uint256 id = tock.createJob{value: 2 ether}(s);
            uint256 g = _estimate(id);
            assertTrue(_runWithGas(id, g));
            emit log_named_uint("calldata bytes", sizes[i]);
            emit log_named_uint("  gas at target, minimal gas", p.got());
            assertGe(p.got(), 1_000_000 - 3_000, "full gas limit, less only the target's own entry cost");
        }
    }

    /// F1c (fixed): an owner used to be able to make a keeper burn gas for nothing — the target
    /// was cheap when simulated and burned everything once the keeper's transaction landed, so
    /// run() ran out of gas after the call. The guard now makes any non-reverting gas limit
    /// enough for the worst case, so the keeper's estimate still pays.
    function test_F1c_flippingTargetCannotMakeKeeperBurnGas() public {
        FlipBurner fb = new FlipBurner();
        bytes memory data = new bytes(1024);
        for (uint256 i; i < data.length; ++i) data[i] = 0x33;
        Tock.JobSpec memory s = Tock.JobSpec(address(fb), data, 0, 60, 0, 300_000, 1 ether, 0.001 ether, 0, "bait");
        vm.prank(mallory);
        uint256 id = tock.createJob{value: 5 ether}(s);

        uint256 g = _estimate(id); // keeper simulates while the target is cheap
        emit log_named_uint("keeper gas limit (bare estimate)", g);
        fb.set(true); // owner front-runs the keeper's transaction

        uint256 ownerBal = tock.balanceOf(mallory);
        uint256 k = keeper.balance;
        vm.cool(address(tock));
        vm.prank(keeper, keeper);
        uint256 g0 = gasleft();
        (bool ok,) = address(tock).call{gas: g}(abi.encodeCall(Tock.run, (id)));
        uint256 burned = g0 - gasleft();
        assertTrue(ok, "the run completes even though the target now burns its whole limit");
        uint256 fee = ownerBal - tock.balanceOf(mallory);
        assertEq(keeper.balance - k, fee);
        assertGe(fee, (burned + 21_000) * 20 gwei, "and the owner, not the keeper, pays for the burn");
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // F2 (fixed): the worst-case bound used to ignore the gas Tock itself spends and anything
    //     that scales with `data`, so FeeCapTooLow / runnable() let through jobs on which the
    //     executor was guaranteed to lose money. With the fee cap set to exactly
    //     worstCaseGas × base fee, the executor must still be made whole.
    // ─────────────────────────────────────────────────────────────────────────────
    function _atTheCap(bytes memory data, address target, string memory label) internal returns (uint256 cost, uint256 fee) {
        Tock.JobSpec memory s = Tock.JobSpec(target, data, 0, 60, 0, 30_000, 1 ether, 0, 0, "probe");
        vm.prank(mallory);
        uint256 probe = tock.createJob{value: 10 ether}(s);
        uint128 cap = uint128(tock.worstCaseGas(probe) * 20 gwei);
        vm.prank(mallory);
        tock.cancel(probe);

        s.maxFee = cap; // the lowest cap that runnable() and FeeCapTooLow accept at 20 gwei
        vm.prank(mallory);
        uint256 id = tock.createJob(s);
        uint256[] memory ids = tock.runnable(0, 100, 20 gwei);
        assertEq(ids.length, 1, "advertised as safe to run");
        assertEq(ids[0], id);
        assertEq(tock.runnable(0, 100, 20 gwei + 1).length, 0, "and not a wei above");

        uint256 ownerBal = tock.balanceOf(mallory);
        vm.cool(address(tock));
        vm.prank(keeper, keeper);
        uint256 g0 = gasleft();
        tock.run(id);
        uint256 used = g0 - gasleft();
        fee = ownerBal - tock.balanceOf(mallory);
        // Execution gas seen from the caller with cold storage, plus intrinsic gas and the
        // transaction's own calldata.
        cost = (used + 21_000 + 700) * 20 gwei;
        emit log_string(label);
        emit log_named_uint("  gas the executor pays for", used + 21_700);
        emit log_named_uint("  gas the executor is paid for", fee / 20 gwei);
        emit log_named_uint("  worstCaseGas", tock.worstCaseGas(id));
        assertLe(fee, cap);
    }

    function test_F2a_executorWholeAtTheCap_burnAllTarget() public {
        Burner b = new Burner();
        (uint256 cost, uint256 fee) = _atTheCap("", address(b), "burn-all target, empty calldata");
        assertGe(fee, cost, "executor is not out of pocket");
    }

    function test_F2b_executorWholeAtTheCap_maxCalldata() public {
        bytes memory data = new bytes(1024);
        for (uint256 i; i < data.length; ++i) data[i] = 0x22;
        (uint256 cost, uint256 fee) = _atTheCap(data, payee, "1 KB calldata to an EOA");
        assertGe(fee, cost, "executor is not out of pocket");
    }

    function test_F2c_executorWholeAtTheCap_burnAllWithMaxCalldata() public {
        Burner b = new Burner();
        bytes memory data = new bytes(1024);
        for (uint256 i; i < data.length; ++i) data[i] = 0x44;
        (uint256 cost, uint256 fee) = _atTheCap(data, address(b), "burn-all target, 1 KB calldata");
        assertGe(fee, cost, "executor is not out of pocket");
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // F3 (fixed): the target used to receive less than `gasLimit` at large limits, because the
    //     Agent keeps 1/64 of what it is given. Tock now hands the Agent 1/63 extra and the
    //     Agent forwards exactly `gasLimit`.
    // ─────────────────────────────────────────────────────────────────────────────
    function test_F3_targetGetsItsFullGasLimit() public {
        GasProbe p = new GasProbe();
        Tock.JobSpec memory s = Tock.JobSpec(address(p), "", 0, HOUR, 0, 5_000_000, 1 ether, 0, 0, "probe");
        vm.prank(alice);
        uint256 id = tock.createJob{value: 10 ether}(s);
        assertTrue(_runWithGas(id, 12_000_000));
        emit log_named_uint("gas the target saw for gasLimit = 5,000,000", p.got());
        assertGe(p.got(), 5_000_000 - 3_000);
        assertLe(p.got(), 5_000_000);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // F4 (fixed): maxRuns could be exceeded — if the last allowed run was also the third
    //     failure, the job was paused instead of ended, and resume() brought it back.
    // ─────────────────────────────────────────────────────────────────────────────
    function test_F4_maxRunsIsFinalEvenWhenTheLastRunFails() public {
        Tock.JobSpec memory s = Tock.JobSpec(payee, "", 1 ether, HOUR, 0, 100_000, 0.02 ether, 0, 3, "3 payments");
        vm.prank(alice);
        uint256 id = tock.createJob{value: 10 ether}(s);
        for (uint256 i; i < 3; ++i) {
            assertTrue(_runWithGas(id, 1_000_000)); // Agent is empty: all three fail
            vm.warp(block.timestamp + HOUR);
        }
        Tock.Job memory j = tock.getJob(id);
        assertEq(j.runs, 3);
        assertFalse(j.active);
        assertEq(j.interval, 0, "ended, not merely paused");
        vm.prank(alice);
        vm.expectRevert(Tock.BadParams.selector);
        tock.resume(id);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Soundness checks (these are expected to hold).
    // ─────────────────────────────────────────────────────────────────────────────

    function _job(address owner, address target, bytes memory data, uint32 gasLimit) internal returns (uint256 id) {
        Tock.JobSpec memory s = Tock.JobSpec(target, data, 0, HOUR, 0, gasLimit, 1 ether, 0, 0, "x");
        vm.prank(owner);
        id = tock.createJob{value: 5 ether}(s);
    }

    /// A job cannot use Arc's sender-preserving system contracts to act as Tock or as the keeper.
    function test_sound_systemContractsCannotSpoofTockOrKeeper() public {
        vm.prank(bob);
        tock.deposit{value: 50 ether}();
        bytes memory xfer = abi.encodeCall(IUSDC.transfer, (mallory, 1e6));

        // Multicall3From.aggregate3([{USDC, allowFailure: true, transfer}])
        bytes memory agg = abi.encodeWithSelector(0x82ad56cb, _calls(xfer));
        uint256 a = _job(mallory, MULTICALL3_FROM, agg, 500_000);
        uint256 b = _job(
            mallory, MEMO, abi.encodeWithSignature("memo(address,bytes,bytes32,bytes)", USDC, xfer, bytes32(0), ""), 500_000
        );
        // CallFrom precompile directly, naming Tock and the keeper as sender
        uint256 c = _job(mallory, CALL_FROM, abi.encodeWithSelector(0x1595ec0b, address(tock), USDC, xfer), 500_000);
        uint256 d = _job(mallory, CALL_FROM, abi.encodeWithSelector(0x1595ec0b, keeper, USDC, xfer), 500_000);
        // native-coin precompile
        uint256 e = _job(
            mallory,
            NATIVE_COIN,
            abi.encodeWithSignature("transfer(address,address,uint256)", address(tock), mallory, 1 ether),
            500_000
        );

        uint256 malloryBefore = mallory.balance;
        uint256 sumBefore = tock.balanceOf(bob) + tock.balanceOf(mallory);
        assertEq(address(tock).balance, sumBefore);
        uint256 keeperBefore = keeper.balance;
        uint256 fees;
        uint256[5] memory ids = [a, b, c, d, e];
        for (uint256 i; i < ids.length; ++i) {
            uint256 ob = tock.balanceOf(mallory);
            assertTrue(_runWithGas(ids[i], 2_000_000));
            fees += ob - tock.balanceOf(mallory);
            emit log_named_uint("job failures", tock.getJob(ids[i]).failures);
        }
        assertEq(mallory.balance, malloryBefore, "nothing reached the attacker");
        assertEq(tock.balanceOf(bob), 50 ether);
        assertEq(address(tock).balance, tock.balanceOf(bob) + tock.balanceOf(mallory), "Tock still solvent");
        assertEq(address(tock).balance, sumBefore - fees, "only fees left");
        assertGe(keeper.balance + 5 * 2_000_000 * 20 gwei, keeperBefore, "keeper was not debited beyond gas");
    }

    function _calls(bytes memory cd) internal pure returns (Call3[] memory calls) {
        calls = new Call3[](1);
        calls[0] = Call3(USDC, true, cd);
    }

    struct Call3 {
        address target;
        bool allowFailure;
        bytes callData;
    }

    /// A return-data bomb from the target costs at most the job's own gas limit.
    function test_sound_returnBombIsBounded() public {
        Bomb bomb = new Bomb();
        uint256 id = _job(alice, address(bomb), "", 300_000);
        vm.cool(address(tock));
        vm.prank(keeper, keeper);
        uint256 g0 = gasleft();
        tock.run(id);
        uint256 used = g0 - gasleft();
        emit log_named_uint("gas for a run against a 200KB return bomb", used);
        emit log_named_uint("failures", tock.getJob(id).failures);
        assertLt(used, 300_000 + 12_000 + 80_000);
    }

    /// A forced native send (SELFDESTRUCT) only ever adds surplus.
    function test_sound_forcedSendOnlyAddsSurplus() public {
        vm.prank(bob);
        tock.deposit{value: 3 ether}();
        Forcer f = new Forcer{value: 1 ether}();
        f.boom(payable(address(tock)));
        assertEq(address(tock).balance, 4 ether);
        vm.prank(bob);
        tock.withdraw(3 ether, payable(bob));
        assertEq(address(tock).balance, 1 ether, "surplus is stuck, nobody can claim it");
    }

    /// Job targets that would let an owner re-enter Tock or drive someone else's Agent.
    function test_sound_agentCannotBeDrivenByAnotherAgent() public {
        uint256 id0 = _job(bob, payee, "", 100_000);
        id0;
        address bobAgent = tock.agentOf(bob);
        vm.deal(bobAgent, 7 ether);
        // mallory's job: her Agent calls bob's Agent.exec(mallory, 7 ether, "")
        uint256 id = _job(mallory, bobAgent, abi.encodeCall(Agent.exec, (mallory, 7 ether, "")), 200_000);
        assertTrue(_runWithGas(id, 2_000_000));
        assertEq(bobAgent.balance, 7 ether);
        assertEq(tock.getJob(id).failures, 1);
        // and her own Agent calling itself is not "Tock or owner" either
        address mAgent = tock.agentOf(mallory);
        uint256 id2 = _job(mallory, mAgent, abi.encodeCall(Agent.exec, (address(tock), 0, abi.encodeCall(Tock.deposit, ()))), 200_000);
        assertTrue(_runWithGas(id2, 2_000_000));
        assertEq(tock.getJob(id2).failures, 1);
    }
}

contract Forcer {
    constructor() payable {}

    function boom(address payable to) external {
        selfdestruct(to);
    }
}
