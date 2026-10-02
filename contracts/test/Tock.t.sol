// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Tock, Agent} from "../src/Tock.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

contract Counter {
    uint256 public count;
    address public lastCaller;

    function bump() external {
        ++count;
        lastCaller = msg.sender;
    }

    function fail() external pure {
        revert("nope");
    }

    function burn() external view {
        while (gasleft() > 2000) {}
    }
}

/// @dev A target that tries to get back into Tock while its job is running.
contract Reenterer {
    Tock immutable TOCK;
    bool public reentered;

    constructor(Tock t) {
        TOCK = t;
    }

    function attack(uint256 jobId) external {
        try TOCK.run(jobId) {
            reentered = true;
        } catch {}
        try TOCK.deposit{value: 0}() {
            reentered = true;
        } catch {}
    }
}

/// @dev Runs against a fork of Arc mainnet (foundry.toml sets `network = "arc"`), where the
///      native balance is USDC with 18 decimals and the ERC-20 view of it has 6.
contract TockTest is Test {
    address constant USDC = 0x3600000000000000000000000000000000000000;
    address constant EURC = 0xbEf5f6d51CB62b58e6A8f77868681825C6fe21c1;

    Tock tock;
    Counter counter;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address payee = makeAddr("payee");
    address keeper = makeAddr("keeper");

    uint128 constant MAX_FEE = 0.02 ether; // 2 cents
    uint128 constant TIP = 0.001 ether;
    uint32 constant HOUR = 1 hours;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ARC_RPC", string("https://rpc.mainnet.arc.io")));
        tock = new Tock();
        counter = new Counter();
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(keeper, 10 ether);
        vm.fee(20 gwei);
    }

    function _spec(address target, bytes memory data, uint128 value) internal pure returns (Tock.JobSpec memory) {
        return Tock.JobSpec(target, data, value, HOUR, 0, 100_000, MAX_FEE, TIP, 0, "job");
    }

    function _payment(address owner, uint128 amount) internal returns (uint256 id) {
        vm.prank(owner);
        id = tock.createJob{value: 1 ether}(_spec(payee, "", amount));
    }

    function _fundAgent(address owner, uint256 amount) internal returns (address agent) {
        agent = tock.agentOf(owner);
        vm.prank(owner);
        (bool ok,) = agent.call{value: amount}("");
        assertTrue(ok);
    }

    // ── setting up ──

    function test_createJob_deploysAgentAtPredictedAddress() public {
        address predicted = tock.predictAgent(alice);
        uint256 id = _payment(alice, 1 ether);
        address agent = tock.agentOf(alice);
        assertEq(agent, predicted);
        assertEq(Agent(payable(agent)).OWNER(), alice);
        assertEq(Agent(payable(agent)).TOCK(), address(tock));
        assertEq(tock.balanceOf(alice), 1 ether, "msg.value becomes the gas balance");
        assertEq(tock.getJob(id).nextRun, block.timestamp, "due immediately by default");
        // a second job reuses the agent
        _payment(alice, 1 ether);
        assertEq(tock.agentOf(alice), agent);
        assertEq(tock.jobsOf(alice).length, 2);
    }

    function test_createJob_validates() public {
        vm.startPrank(alice);
        Tock.JobSpec memory s = _spec(address(0), "", 0);
        vm.expectRevert(Tock.BadParams.selector);
        tock.createJob(s);
        s = _spec(address(tock), "", 0); // Tock may not be made to call itself
        vm.expectRevert(Tock.BadParams.selector);
        tock.createJob(s);
        s = _spec(payee, "", 0);
        s.interval = 59;
        vm.expectRevert(Tock.BadParams.selector);
        tock.createJob(s);
        s = _spec(payee, "", 0);
        s.gasLimit = 10;
        vm.expectRevert(Tock.BadParams.selector);
        tock.createJob(s);
        s = _spec(payee, "", 0);
        s.tip = MAX_FEE + 1;
        vm.expectRevert(Tock.BadParams.selector);
        tock.createJob(s);
        vm.stopPrank();
    }

    function test_depositAndWithdraw() public {
        vm.prank(alice);
        tock.deposit{value: 3 ether}();
        vm.prank(bob);
        tock.depositFor{value: 1 ether}(alice);
        assertEq(tock.balanceOf(alice), 4 ether);
        vm.prank(bob);
        vm.expectRevert(); // bob has no balance of his own
        tock.withdraw(1, payable(bob));
        uint256 before = alice.balance;
        vm.prank(alice);
        tock.withdraw(4 ether, payable(alice));
        assertEq(alice.balance, before + 4 ether);
        assertEq(address(tock).balance, 0);
    }

    // ── a scheduled payment: the whole point ──

    function test_run_scheduledPayment() public {
        uint256 id = _payment(alice, 2.5 ether); // 2.50 USDC per run
        address agent = _fundAgent(alice, 10 ether);

        uint256 keeperBefore = keeper.balance;
        vm.prank(keeper);
        uint256 g = gasleft();
        tock.run(id);
        uint256 callGas = g - gasleft();

        assertEq(payee.balance, 2.5 ether, "payee received native USDC");
        assertEq(IERC20(USDC).balanceOf(payee), 2.5e6, "which is the same balance the ERC-20 shows");
        assertEq(agent.balance, 7.5 ether);

        uint256 fee = keeper.balance - keeperBefore;
        assertEq(tock.balanceOf(alice), 1 ether - fee, "fee comes out of the owner's gas balance");
        assertEq(address(tock).balance, tock.balanceOf(alice), "Tock holds exactly what it owes");
        uint256 cost = (callGas + 21_000) * block.basefee;
        assertGe(fee, cost + TIP, "executor is made whole");
        assertLe(fee, cost * 150 / 100 + TIP, "and not much more");
        assertLe(fee, MAX_FEE);
        emit log_named_uint("call gas", callGas);
        emit log_named_uint("fee (wei of USDC)", fee);

        Tock.Job memory j = tock.getJob(id);
        assertEq(j.runs, 1);
        assertEq(j.nextRun, block.timestamp + HOUR);
    }

    function test_run_notDueReverts() public {
        uint256 id = _payment(alice, 1 ether);
        _fundAgent(alice, 5 ether);
        vm.prank(keeper);
        tock.run(id);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Tock.NotDue.selector, uint40(block.timestamp + HOUR)));
        tock.run(id);
    }

    function test_run_lateDoesNotBurst() public {
        uint256 id = _payment(alice, 1 ether);
        _fundAgent(alice, 50 ether);
        vm.warp(block.timestamp + 10 * uint256(HOUR) + 5);
        vm.prank(keeper);
        tock.run(id);
        assertEq(tock.getJob(id).nextRun, block.timestamp + HOUR, "no catch-up runs queued");
        vm.prank(keeper);
        vm.expectRevert();
        tock.run(id);
        assertEq(payee.balance, 1 ether);
    }

    function test_run_onTimeKeepsCadence() public {
        uint256 id = _payment(alice, 1 ether);
        _fundAgent(alice, 50 ether);
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 10 minutes);
        vm.prank(keeper);
        tock.run(id);
        assertEq(tock.getJob(id).nextRun, t0 + HOUR, "cadence anchored to the schedule, not the run");
    }

    function test_run_contractCall_isFromTheOwnersAgent() public {
        vm.prank(alice);
        uint256 id = tock.createJob{value: 1 ether}(_spec(address(counter), abi.encodeCall(Counter.bump, ()), 0));
        vm.prank(keeper);
        tock.run(id);
        assertEq(counter.count(), 1);
        assertEq(counter.lastCaller(), tock.agentOf(alice), "msg.sender is the owner's Agent, never Tock");
    }

    function test_run_eurcPayment() public {
        vm.prank(alice);
        uint256 id =
            tock.createJob{value: 1 ether}(_spec(EURC, abi.encodeCall(IERC20.transfer, (payee, 3e6)), 0));
        deal(EURC, tock.agentOf(alice), 10e6);
        vm.prank(keeper);
        tock.run(id);
        assertEq(IERC20(EURC).balanceOf(payee), 3e6);
    }

    // ── money safety ──

    function test_run_underfundedReverts() public {
        vm.prank(alice);
        uint256 id = tock.createJob{value: MAX_FEE - 1}(_spec(payee, "", 0));
        vm.prank(keeper);
        vm.expectRevert(Tock.Underfunded.selector);
        tock.run(id);
    }

    function test_run_feeCapProtectsExecutorWhenBaseFeeSpikes() public {
        uint256 id = _payment(alice, 1 ether);
        _fundAgent(alice, 5 ether);
        vm.fee(20_000 gwei); // Arc's ceiling: a run would cost far more than the 2-cent cap
        vm.prank(keeper);
        vm.expectRevert(Tock.FeeCapTooLow.selector);
        tock.run(id);
        assertEq(tock.runnable(0, 10, 20_000 gwei).length, 0, "and it is not advertised as runnable");
        vm.fee(20 gwei);
        assertEq(tock.runnable(0, 10, 20 gwei).length, 1);
    }

    function test_run_feeNeverExceedsCap() public {
        vm.prank(alice);
        Tock.JobSpec memory s = _spec(address(counter), abi.encodeCall(Counter.burn, ()), 0);
        s.gasLimit = 400_000;
        uint256 id = tock.createJob{value: 1 ether}(s);
        assertLe(tock.worstCaseGas(id) * 20 gwei, MAX_FEE, "test premise: the cap covers a full burn at 20 gwei");
        uint256 k = keeper.balance;
        vm.prank(keeper);
        tock.run(id);
        uint256 fee = keeper.balance - k;
        assertLe(fee, MAX_FEE);
        assertGt(fee, 300_000 * block.basefee, "a gas-hungry call is paid for by its owner");
    }

    function test_run_refundIgnoresTxGasPrice() public {
        uint256 warm = _payment(alice, 0.1 ether);
        uint256 a = _payment(alice, 0.1 ether);
        uint256 b = _payment(alice, 0.1 ether);
        _fundAgent(alice, 5 ether);
        vm.prank(keeper);
        tock.run(warm); // absorbs the once-per-transaction overhead (a test is one transaction)

        uint256 k = keeper.balance;
        vm.txGasPrice(20 gwei);
        vm.prank(keeper);
        tock.run(a);
        uint256 feeLow = keeper.balance - k;
        k = keeper.balance;
        vm.txGasPrice(5000 gwei);
        vm.prank(keeper);
        tock.run(b);
        assertApproxEqAbs(keeper.balance - k, feeLow, 200 * 20 gwei, "overbidding does not raise the fee");
    }

    function test_run_cannotStarveTheCall() public {
        vm.prank(alice);
        uint256 id = tock.createJob{value: 1 ether}(_spec(address(counter), abi.encodeCall(Counter.bump, ()), 0));
        // Not enough gas to give the call its 100k: the run must revert, not "fail" the job
        // and collect a fee.
        vm.prank(keeper);
        (bool ok, bytes memory ret) = address(tock).call{gas: 120_000}(abi.encodeCall(Tock.run, (id)));
        assertFalse(ok);
        assertEq(bytes4(ret), Tock.InsufficientGas.selector);
        assertEq(tock.getJob(id).runs, 0);
        assertEq(tock.balanceOf(alice), 1 ether);
    }

    // ── failures ──

    function test_failingJobStillPaysExecutorAndPausesItself() public {
        // An Agent with no funds cannot make its payment.
        uint256 id = _payment(alice, 1 ether);
        for (uint256 i; i < 3; ++i) {
            uint256 k = keeper.balance;
            vm.prank(keeper);
            tock.run(id);
            assertGt(keeper.balance, k, "the executor did the work and is paid");
            vm.warp(block.timestamp + HOUR);
        }
        Tock.Job memory j = tock.getJob(id);
        assertEq(j.failures, 3);
        assertFalse(j.active, "three strikes: paused, so the gas balance is not drained");
        vm.prank(keeper);
        vm.expectRevert(Tock.JobInactive.selector);
        tock.run(id);

        _fundAgent(alice, 5 ether);
        vm.prank(alice);
        tock.resume(id);
        vm.warp(block.timestamp + HOUR);
        vm.prank(keeper);
        tock.run(id);
        assertEq(tock.getJob(id).failures, 0);
        assertEq(payee.balance, 1 ether);
    }

    function test_revertingTargetCountsAsFailure() public {
        vm.prank(alice);
        uint256 id = tock.createJob{value: 1 ether}(_spec(address(counter), abi.encodeCall(Counter.fail, ()), 0));
        vm.prank(keeper);
        tock.run(id);
        assertEq(tock.getJob(id).failures, 1);
        assertTrue(tock.getJob(id).active);
    }

    function test_maxRunsEndsTheJob() public {
        vm.prank(alice);
        Tock.JobSpec memory s = _spec(address(counter), abi.encodeCall(Counter.bump, ()), 0);
        s.maxRuns = 2;
        uint256 id = tock.createJob{value: 1 ether}(s);
        vm.prank(keeper);
        tock.run(id);
        vm.warp(block.timestamp + HOUR);
        vm.prank(keeper);
        tock.run(id);
        assertFalse(tock.getJob(id).active);
        vm.prank(alice);
        vm.expectRevert(Tock.BadParams.selector);
        tock.resume(id); // finished jobs do not come back
    }

    // ── isolation ──

    function test_agentOnlyObeysTockAndItsOwner() public {
        _payment(alice, 1 ether);
        address agent = _fundAgent(alice, 5 ether);
        vm.prank(bob);
        vm.expectRevert(Agent.NotAuthorized.selector);
        Agent(payable(agent)).exec(bob, 5 ether, "");
        // the owner can always take the money back out
        vm.prank(alice);
        assertTrue(Agent(payable(agent)).exec(alice, 5 ether, ""));
        assertEq(agent.balance, 0);
    }

    /// @dev The dangerous case for any automation contract on Arc: USDC's ERC-20 interface moves
    ///      the caller's *native* balance, and Tock holds everyone's gas money natively. Because
    ///      jobs run from the owner's Agent, a job that calls USDC can only spend that Agent.
    function test_jobCallingUsdcCannotTouchTocksBalance() public {
        vm.prank(bob);
        tock.deposit{value: 20 ether}(); // someone else's gas money sits in Tock
        vm.startPrank(alice);
        uint256 steal = tock.createJob{value: 1 ether}(_spec(USDC, abi.encodeCall(IERC20.transfer, (alice, 20e6)), 0));
        uint256 approve =
            tock.createJob(_spec(USDC, abi.encodeCall(IERC20.approve, (alice, type(uint256).max)), 0));
        vm.stopPrank();
        uint256 tockBefore = address(tock).balance;
        vm.startPrank(keeper);
        tock.run(steal);
        tock.run(approve);
        vm.stopPrank();
        assertEq(tock.balanceOf(bob), 20 ether);
        assertGe(address(tock).balance, tockBefore - 2 * uint256(MAX_FEE), "only executor fees left Tock");
        assertEq(address(tock).balance, tock.balanceOf(alice) + tock.balanceOf(bob));
        // the approval alice obtained is over her own Agent, not over Tock
        vm.prank(alice);
        (bool ok,) = USDC.call(abi.encodeWithSignature("transferFrom(address,address,uint256)", address(tock), alice, 1e6));
        assertFalse(ok);
    }

    function test_targetCannotReenter() public {
        Reenterer r = new Reenterer(tock);
        vm.prank(alice);
        uint256 id = tock.createJob{value: 1 ether}(_spec(address(r), "", 0));
        vm.prank(alice);
        Tock.JobSpec memory s = _spec(address(r), abi.encodeCall(Reenterer.attack, (id)), 0);
        s.gasLimit = 300_000;
        uint256 attackJob = tock.createJob(s);
        vm.prank(keeper);
        tock.run(attackJob);
        assertFalse(r.reentered());
        assertEq(tock.getJob(id).runs, 0);
    }

    function test_onlyOwnerManagesAJob() public {
        uint256 id = _payment(alice, 1 ether);
        vm.startPrank(bob);
        vm.expectRevert(Tock.NotOwner.selector);
        tock.pause(id);
        vm.expectRevert(Tock.NotOwner.selector);
        tock.cancel(id);
        vm.expectRevert(Tock.NotOwner.selector);
        tock.resume(id);
        vm.stopPrank();
        vm.prank(alice);
        tock.cancel(id);
        vm.prank(keeper);
        vm.expectRevert(Tock.JobInactive.selector);
        tock.run(id);
    }

    // ── batches ──

    function test_runBatch_skipsWhatCannotRun() public {
        uint256 good = _payment(alice, 1 ether);
        _fundAgent(alice, 5 ether);
        vm.prank(bob);
        uint256 broke = tock.createJob(_spec(payee, "", 0)); // no gas balance at all
        uint256[] memory ids = new uint256[](4);
        (ids[0], ids[1], ids[2], ids[3]) = (good, broke, 999, good);
        uint256 k = keeper.balance;
        vm.prank(keeper);
        assertEq(tock.runBatch(ids), 1);
        assertGt(keeper.balance, k);
        assertEq(tock.getJob(good).runs, 1);
        assertEq(tock.getJob(broke).runs, 0);
    }

    function test_runBatch_revertsRatherThanStarveAJob() public {
        uint256 a = _payment(alice, 1 ether);
        uint256[] memory ids = new uint256[](1);
        ids[0] = a;
        vm.prank(keeper);
        (bool ok, bytes memory ret) = address(tock).call{gas: 130_000}(abi.encodeCall(Tock.runBatch, (ids)));
        assertFalse(ok);
        assertEq(bytes4(ret), Tock.InsufficientGas.selector);
    }

    function test_runFor_onlySelf() public {
        uint256 id = _payment(alice, 1 ether);
        vm.prank(keeper);
        vm.expectRevert(Tock.NotAuthorized.selector);
        tock.runFor(id, keeper);
    }

    function test_runnable_filters() public {
        uint256 a = _payment(alice, 1 ether);
        vm.prank(bob);
        tock.createJob(_spec(payee, "", 0)); // unfunded
        vm.prank(alice);
        Tock.JobSpec memory later = _spec(payee, "", 0);
        later.firstRun = uint40(block.timestamp + 1 days);
        tock.createJob(later); // not due
        uint256[] memory ids = tock.runnable(0, 100, 20 gwei);
        assertEq(ids.length, 1);
        assertEq(ids[0], a);
    }

    /// @dev Whatever the base fee, tip and gas appetite: Tock's balance always equals what it
    ///      owes its owners, and no run costs more than its cap.
    function testFuzz_solvency(uint64 baseFee, uint128 tip, uint32 gasLimit, bool failing) public {
        baseFee = uint64(bound(baseFee, 20 gwei, 20_000 gwei));
        gasLimit = uint32(bound(gasLimit, 30_000, 1_000_000));
        uint128 maxFee = 25 ether; // covers a full burn even at the base fee ceiling
        tip = uint128(bound(tip, 0, maxFee));
        vm.prank(bob);
        tock.deposit{value: 7 ether}();
        vm.prank(alice);
        uint256 id = tock.createJob{value: 60 ether}(
            Tock.JobSpec(
                address(counter),
                failing ? abi.encodeCall(Counter.fail, ()) : abi.encodeCall(Counter.burn, ()),
                0,
                HOUR,
                0,
                gasLimit,
                maxFee,
                tip,
                0,
                "f"
            )
        );
        vm.fee(baseFee);
        uint256 k = keeper.balance;
        vm.prank(keeper);
        tock.run(id);
        uint256 fee = keeper.balance - k;
        assertLe(fee, maxFee);
        assertEq(tock.balanceOf(alice), 60 ether - fee);
        assertEq(address(tock).balance, tock.balanceOf(alice) + tock.balanceOf(bob));
    }
}
