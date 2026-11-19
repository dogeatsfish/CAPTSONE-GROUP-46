"""Checks the engine_sim Python module -- the service's view of the engine.

Plain asserts, no pytest needed. Run it with `make -C sw/engine test-python`,
which builds the module first, or directly once engine_sim*.so exists:

    python3 sw/service/tests/test_bindings.py
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))        # sw/service/tests
SW = os.path.dirname(os.path.dirname(HERE))              # sw
sys.path.insert(0, os.path.join(SW, "engine", "build"))  # where the .so is built

import engine_sim as es  # noqa: E402

DATA = os.path.join(SW, "data_pipeline", "data", "synthetic_mbo_stream.bin")
FEED = 0


def test_orderbook_direct():
    book = es.OrderBook()
    events = book.process_add(es.Order(1, "S", 10.0, 50), 1)
    assert [e.type_name for e in events] == ["Accepted"]
    book.process_add(es.Order(2, "S", 10.0, 20), 1)

    l2 = book.get_l2_state(5)
    assert len(l2.asks) == 1 and l2.asks[0].size == 70 and l2.asks[0].order_count == 2
    assert l2.bids == []

    pos = book.queue_position(2)
    assert pos.shares_ahead == 50 and pos.orders_ahead == 1 and pos.side == "S"
    assert book.queue_position(99) is None

    taker = es.Order(3, "B", 10.0, 60)
    events = book.process_add(taker, 2)
    assert taker.size == 0  # updated in place: nothing left unfilled
    kinds = [e.type for e in events]
    assert kinds.count(es.BookEventType.Trade) == 2
    fill = events[2]
    assert fill.type == es.BookEventType.PartialFill and fill.liquidity == "T"
    assert fill.side == "B" and fill.contra_order_id == 1

    assert book.process_reduce(2, 4, 3)[0].type == es.BookEventType.Reduced
    rejected = book.process_cancel(99, 3)[0]
    assert rejected.type == es.BookEventType.Rejected
    assert rejected.reason == es.RejectReason.UnknownOrderId
    assert rejected.reason_name == "UnknownOrderId" and rejected.side == ""

    snap = book.snapshot(5)
    other = es.OrderBook()
    other.restore(snap)
    assert other.get_l1_state().best_ask == 10.0
    assert other.get_l2_state(1).asks[0].size == book.get_l2_state(1).asks[0].size


class Lifter(es.Participant):
    """Buys 10 at the offer the first time it sees one; records what it hears."""

    def __init__(self):
        es.Participant.__init__(self)
        self.order_id = 0
        self.saw_book_at = None
        self.fills = []
        self.updates = []
        self.trades = []
        self.timers = []

    def on_book_update(self, book):
        if self.order_id == 0 and book.asks:
            self.saw_book_at = self.now()
            self.order_id = self.send_limit("B", book.asks[0].price, 10)

    def on_fill(self, event):
        self.fills.append((self.now(), event))

    def on_order_update(self, event):
        self.updates.append(event)

    def on_trade(self, event):
        self.trades.append(event)

    def on_timer(self, now_ns):
        self.timers.append(now_ns)


def test_python_participant():
    sched = es.Scheduler(seed=7)
    sched.record_events(True)
    sched.set_fees(es.FeeSchedule(taker_fee=0.003, maker_rebate=0.002))
    bot = Lifter()
    sched.add_participant(1, bot, es.LatencyProfile.uniform(30_000, 50_000, 20_000))
    assert sched.is_registered(1) and not sched.is_registered(2) and bot.id == 1

    sched.schedule(1_000_000, FEED, es.Action.add(es.Order(1, "S", 10.0, 50)))
    steps = sched.run()
    assert steps > 3 and sched.empty()

    assert bot.saw_book_at == 1_030_000                # t + L_in
    accepted = [e for e in sched.event_log if e.order_id == bot.order_id][0]
    assert accepted.timestamp_ns == 1_100_000          # + compute + L_out
    assert len(bot.fills) == 1
    heard_at, fill = bot.fills[0]
    assert heard_at == 1_130_000 and fill.type == es.BookEventType.Filled
    assert [e.type_name for e in bot.updates] == ["Accepted"]
    assert len(bot.trades) == 1

    acct = sched.account(1)
    assert acct.position == 10 and abs(acct.cash - (-100.03)) < 1e-9
    assert abs(acct.fees_paid - 0.03) < 1e-9 and acct.orders_sent == 1
    assert acct.open_orders == {} and len(acct.fills) == 1
    assert acct.fills[0].liquidity == "T"
    assert bot.account.position == 10                  # same account, seen from the bot
    assert abs(acct.net_pnl(10.5) - (5.0 - 0.03)) < 1e-9

    assert sched.book.get_l2_state(1).asks[0].size == 40

    try:
        sched.account(99)
        raise AssertionError("expected IndexError")
    except IndexError:
        pass
    try:
        sched.step()
        raise AssertionError("expected RuntimeError")
    except RuntimeError:
        pass


def test_stepping_and_resting_orders():
    sched = es.Scheduler()
    bot = Lifter()
    sched.add_participant(1, bot)
    bot.order_id = bot.send_limit("B", 9.0, 25)        # rest a bid directly
    sched.run()
    assert sched.account(1).open_orders[bot.order_id].remaining == 25
    sched.schedule(10, FEED, es.Action.add(es.Order(5, "B", 9.0, 40)))
    sched.schedule(20, FEED, es.Action.add(es.Order(6, "S", 9.0, 10)))

    step = sched.step()                                 # the feed's bid joins behind
    assert step.kind == es.StepKind.BookAction and step.participant == FEED
    assert step.time_ns == 10 and step.action.type == es.ActionType.Add
    assert bot.queue_position(bot.order_id).shares_ahead == 0
    assert sched.book.queue_position(5).shares_ahead == 25

    assert sched.run_until(20) >= 1                     # the sell hits the bot first
    sched.run()
    assert sched.account(1).position == 10
    assert bot.fills[0][1].liquidity == "M"
    assert bot.fills[0][1].type == es.BookEventType.PartialFill

    bot.set_timer(500)
    bot.cancel(bot.order_id)
    sched.run()
    assert bot.timers == [520] and sched.account(1).open_orders == {}
    assert sched.account(1).cancels_sent == 1


def test_snapshots_and_determinism():
    def run(seed):
        sched = es.Scheduler(seed=seed)
        sched.record_events(True)
        sched.set_snapshot_interval(1_000)
        t = 0
        for oid in range(1, 201):
            r = sched.random_u64()
            t += r % 100
            side = "B" if (r >> 10) & 1 else "S"
            price = 100.0 + ((r >> 11) % 11) - 5
            sched.schedule(t, FEED, es.Action.add(es.Order(oid, side, price, 1 + (r >> 20) % 20)))
        sched.run()
        log = [(e.seq, e.timestamp_ns, e.type_name, e.order_id, e.price, e.size) for e in sched.event_log]
        return log, sched.snapshots

    log_a, snaps = run(11)
    log_b, _ = run(11)
    log_c, _ = run(12)
    assert log_a == log_b and log_a != log_c and len(log_a) > 200
    assert len(snaps) >= 2 and snaps[0].timestamp_ns < snaps[1].timestamp_ns
    assert snaps[-1].next_event_seq > snaps[0].next_event_seq

    resumed = es.Scheduler()
    resumed.restore(snaps[0])
    assert resumed.now == snaps[0].timestamp_ns
    l2 = resumed.book.get_l2_state(50)
    assert sum(lv.order_count for lv in l2.bids) == len(snaps[0].bids)


def test_latency_presets():
    colo = es.latency_preset(es.LatencyTier.Colo, home=2)
    assert colo.leg(2).in_ns < colo.leg(0).in_ns
    retail = es.latency_preset(es.LatencyTier.Retail)
    assert retail.leg(0).out_ns > colo.leg(0).out_ns
    profile = es.LatencyProfile()
    profile.set(4, es.LatencyLeg(in_ns=10, out_ns=20))
    profile.compute_ns = 7
    assert profile.leg(4).out_ns == 20 and profile.leg(5).out_ns == 0


def test_offline_simulation_options():
    plain = es.OfflineSimulation(DATA).run()
    assert plain.events == [] and plain.book_snapshots == []
    assert plain.total_trades > 0 and len(plain.pnl_curve) > 0

    sim = es.OfflineSimulation(DATA)
    sim.set_record_events(True)
    sim.set_snapshot_interval(60 * 1_000_000_000)
    sim.set_fees(es.FeeSchedule(taker_fee=0.003, maker_rebate=0.002))
    result = sim.run()
    assert len(result.events) > len(result.trades) and len(result.book_snapshots) > 10
    assert [e.seq for e in result.events[:5]] == [1, 2, 3, 4, 5]
    acct = sim.player_account
    assert acct.fees_paid != 0 and acct.volume > 0
    # Fees are booked separately, so they do not change what trades.
    assert result.total_trades == plain.total_trades

    slow = es.OfflineSimulation(DATA)
    slow.set_player_latency(es.latency_preset(es.LatencyTier.Retail))
    slow_result = slow.run()
    fast_final = plain.pnl_curve[-1]
    slow_final = slow_result.pnl_curve[-1]
    # A 50 ms round trip changes the outcome of the same strategy.
    assert (slow_result.total_trades, slow_final.realized_pnl) != (
        plain.total_trades, fast_final.realized_pnl)
    print(f"      zero latency: {plain.total_trades} trades, realized {fast_final.realized_pnl:.2f}")
    print(f"      retail tier : {slow_result.total_trades} trades, realized {slow_final.realized_pnl:.2f}")


def main():
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    failed = 0
    for test in tests:
        try:
            test()
            print(f"ok    {test.__name__}")
        except Exception:  # noqa: BLE001 - report every failure, then exit non-zero
            import traceback
            failed += 1
            print(f"FAIL  {test.__name__}")
            traceback.print_exc()
    print("FAILED" if failed else "PASSED", f"({failed} failed)")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
