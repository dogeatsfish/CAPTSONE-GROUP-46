// Pybind11 bindings exposing the C++ engine to Python as `engine_sim`.
//
// Two levels of use:
//
//   1. Run a whole file through the built-in strategy:
//
//        import engine_sim
//        sim = engine_sim.OfflineSimulation("data/synthetic_mbo_stream.bin")
//        sim.set_player_latency(engine_sim.latency_preset(engine_sim.LatencyTier.Colo))
//        sim.set_record_events(True)
//        result = sim.run()
//        print(result.total_trades, len(result.events))
//
//   2. Drive the scheduler yourself, with participants written in Python:
//
//        class Bot(engine_sim.Participant):
//            def on_book_update(self, book):
//                if book.asks:
//                    self.send_limit("B", book.asks[0].price, 10)
//
//        sched = engine_sim.Scheduler(seed=42)
//        bot = Bot()
//        sched.add_participant(1, bot)
//        sched.schedule(100, 0, engine_sim.Action.add(engine_sim.Order(1, "S", 10.0, 50)))
//        sched.run()
//        print(sched.account(1).position, sched.book.get_l2_state(5).asks)

#include <pybind11/pybind11.h>
#include <pybind11/stl.h>       // std::vector <-> list, std::map <-> dict, std::optional <-> None

#include <stdexcept>
#include <string>

#include "participant.h"
#include "offline_simulation.h"
// OnlineSimulation uses POSIX sockets and isn't buildable on native Windows
// yet (see the Windows branch of the pymodule target in engine/Makefile,
// which defines CT_NO_ONLINE_SIM). macOS/Linux builds are unaffected.
#ifndef CT_NO_ONLINE_SIM
#include "online_simulation.h"
#endif

namespace py = pybind11;

namespace {

// A char field as a Python str; '\0' (meaning "not set") becomes "".
std::string char_str(char c) {
    return c == 0 ? std::string() : std::string(1, c);
}

// "B" -> 'B'; "" -> '\0'.
char str_char(const std::string& s) {
    if (s.size() > 1) throw py::value_error("expected a single character, got '" + s + "'");
    return s.empty() ? '\0' : s[0];
}

// Lets a Python class subclass Participant: each callback looks for a Python
// override and falls back to the C++ default (do nothing).
class PyParticipant : public Participant {
public:
    void on_book_update(const L2State& book) override {
        PYBIND11_OVERRIDE(void, Participant, on_book_update, book);
    }
    void on_trade(const BookEvent& event) override {
        PYBIND11_OVERRIDE(void, Participant, on_trade, event);
    }
    void on_fill(const BookEvent& event) override {
        PYBIND11_OVERRIDE(void, Participant, on_fill, event);
    }
    void on_order_update(const BookEvent& event) override {
        PYBIND11_OVERRIDE(void, Participant, on_order_update, event);
    }
    void on_timer(uint64_t now_ns) override {
        PYBIND11_OVERRIDE(void, Participant, on_timer, now_ns);
    }
};

// Participant's action helpers are protected in C++ (only the participant
// itself may call them); this re-exports them so they can be bound as methods.
class ParticipantAccess : public Participant {
public:
    using Participant::account;
    using Participant::cancel;
    using Participant::now;
    using Participant::queue_position;
    using Participant::reduce;
    using Participant::replace;
    using Participant::send_limit;
    using Participant::send_market;
    using Participant::set_timer;
};

void bind_market_types(py::module_& m) {
    py::class_<Order>(m, "Order")
        .def(py::init([](uint64_t order_id, const std::string& side, double price, double size) {
                 return Order{order_id, price, size, str_char(side), false};
             }),
             py::arg("order_id"), py::arg("side"), py::arg("price"), py::arg("size"))
        .def_readwrite("order_id", &Order::order_id)
        .def_readwrite("price", &Order::price)
        .def_readwrite("size", &Order::size)
        .def_property("side", [](const Order& o) { return char_str(o.side); },
                      [](Order& o, const std::string& v) { o.side = str_char(v); })
        .def("__repr__", [](const Order& o) {
            return "<Order id=" + std::to_string(o.order_id) + " side=" + char_str(o.side) +
                   " price=" + std::to_string(o.price) + " size=" + std::to_string(o.size) + ">";
        });

    py::class_<L1State>(m, "L1State")
        .def_readonly("best_bid", &L1State::best_bid)
        .def_readonly("best_ask", &L1State::best_ask);

    py::class_<L2Level>(m, "L2Level")
        .def_readonly("price", &L2Level::price)
        .def_readonly("size", &L2Level::size)
        .def_readonly("order_count", &L2Level::order_count)
        .def("__repr__", [](const L2Level& l) {
            return "<L2Level price=" + std::to_string(l.price) + " size=" +
                   std::to_string(l.size) + " orders=" + std::to_string(l.order_count) + ">";
        });

    py::class_<L2State>(m, "L2State")
        .def_readonly("bids", &L2State::bids, "Highest price first.")
        .def_readonly("asks", &L2State::asks, "Lowest price first.");

    py::class_<QueuePosition>(m, "QueuePosition")
        .def_property_readonly("side", [](const QueuePosition& q) { return char_str(q.side); })
        .def_readonly("price", &QueuePosition::price)
        .def_readonly("remaining", &QueuePosition::remaining)
        .def_readonly("shares_ahead", &QueuePosition::shares_ahead)
        .def_readonly("orders_ahead", &QueuePosition::orders_ahead);

    py::class_<BookSnapshot>(m, "BookSnapshot")
        .def_readonly("timestamp_ns", &BookSnapshot::timestamp_ns)
        .def_readonly("next_event_seq", &BookSnapshot::next_event_seq)
        .def_readonly("bids", &BookSnapshot::bids, "Best price first, oldest first within a price.")
        .def_readonly("asks", &BookSnapshot::asks);

    py::enum_<BookEventType>(m, "BookEventType")
        .value("Accepted", BookEventType::Accepted)
        .value("Trade", BookEventType::Trade)
        .value("PartialFill", BookEventType::PartialFill)
        .value("Filled", BookEventType::Filled)
        .value("Reduced", BookEventType::Reduced)
        .value("Cancelled", BookEventType::Cancelled)
        .value("Rejected", BookEventType::Rejected);

    py::enum_<RejectReason>(m, "RejectReason")
        .value("None_", RejectReason::None) // None is a Python keyword
        .value("InvalidSide", RejectReason::InvalidSide)
        .value("InvalidSize", RejectReason::InvalidSize)
        .value("InvalidPrice", RejectReason::InvalidPrice)
        .value("UnknownOrderId", RejectReason::UnknownOrderId);

    py::class_<BookEvent>(m, "BookEvent")
        .def_readonly("seq", &BookEvent::seq)
        .def_readonly("timestamp_ns", &BookEvent::timestamp_ns)
        .def_readonly("type", &BookEvent::type)
        .def_property_readonly("type_name",
                               [](const BookEvent& e) { return std::string(to_string(e.type)); })
        .def_readonly("order_id", &BookEvent::order_id)
        .def_readonly("contra_order_id", &BookEvent::contra_order_id)
        .def_property_readonly("side", [](const BookEvent& e) { return char_str(e.side); })
        .def_property_readonly("liquidity",
                               [](const BookEvent& e) { return char_str(e.liquidity); },
                               "'T' taker / 'M' maker on fills, '' otherwise.")
        .def_readonly("price", &BookEvent::price)
        .def_readonly("size", &BookEvent::size)
        .def_readonly("remaining", &BookEvent::remaining)
        .def_readonly("reason", &BookEvent::reason)
        .def_property_readonly("reason_name",
                               [](const BookEvent& e) { return std::string(to_string(e.reason)); })
        .def("__repr__", [](const BookEvent& e) {
            return "<BookEvent #" + std::to_string(e.seq) + " " + to_string(e.type) +
                   " order=" + std::to_string(e.order_id) + " side=" + char_str(e.side) +
                   " price=" + std::to_string(e.price) + " size=" + std::to_string(e.size) +
                   " remaining=" + std::to_string(e.remaining) + ">";
        });

    py::class_<OrderBook>(m, "OrderBook")
        .def(py::init<>())
        // The process_* calls update the Order passed in (its size becomes
        // the unfilled remainder) and return the list of events.
        .def("process_add", &OrderBook::process_add, py::arg("order"), py::arg("timestamp_ns"))
        .def("process_market", &OrderBook::process_market, py::arg("order"),
             py::arg("timestamp_ns"))
        .def("process_cancel",
             [](OrderBook& b, uint64_t order_id, uint64_t ts, const std::string& side) {
                 return b.process_cancel(order_id, ts, str_char(side));
             },
             py::arg("order_id"), py::arg("timestamp_ns"), py::arg("side") = "")
        .def("process_reduce",
             [](OrderBook& b, uint64_t order_id, double qty, uint64_t ts, const std::string& side) {
                 return b.process_reduce(order_id, qty, ts, str_char(side));
             },
             py::arg("order_id"), py::arg("qty"), py::arg("timestamp_ns"), py::arg("side") = "")
        .def("process_replace", &OrderBook::process_replace, py::arg("old_order_id"),
             py::arg("new_order"), py::arg("timestamp_ns"))
        .def("get_l1_state", &OrderBook::get_l1_state)
        .def("get_l2_state", &OrderBook::get_l2_state, py::arg("n_levels"),
             "Size and order count per price level, best n_levels per side.")
        .def("queue_position", &OrderBook::queue_position, py::arg("order_id"),
             "Shares queued ahead of a resting order, or None if it is not resting.")
        .def("snapshot", &OrderBook::snapshot, py::arg("timestamp_ns"))
        .def("restore", &OrderBook::restore, py::arg("snapshot"));
}

void bind_accounts_and_latency(py::module_& m) {
    py::class_<FeeSchedule>(m, "FeeSchedule")
        .def(py::init([](double taker_fee, double maker_rebate) {
                 return FeeSchedule{taker_fee, maker_rebate};
             }),
             py::arg("taker_fee") = 0.0, py::arg("maker_rebate") = 0.0,
             "Per-share fee paid by the taker and rebate paid to the maker.")
        .def_readwrite("taker_fee", &FeeSchedule::taker_fee)
        .def_readwrite("maker_rebate", &FeeSchedule::maker_rebate);

    py::class_<OpenOrder>(m, "OpenOrder")
        .def_property_readonly("side", [](const OpenOrder& o) { return char_str(o.side); })
        .def_readonly("price", &OpenOrder::price)
        .def_readonly("remaining", &OpenOrder::remaining);

    py::class_<FillRecord>(m, "FillRecord")
        .def_readonly("timestamp_ns", &FillRecord::timestamp_ns)
        .def_readonly("order_id", &FillRecord::order_id)
        .def_property_readonly("side", [](const FillRecord& f) { return char_str(f.side); })
        .def_property_readonly("liquidity",
                               [](const FillRecord& f) { return char_str(f.liquidity); })
        .def_readonly("price", &FillRecord::price)
        .def_readonly("size", &FillRecord::size)
        .def_readonly("fee", &FillRecord::fee, "> 0 fee paid, < 0 rebate received.");

    // Read-only from Python: accounts are written by the scheduler.
    py::class_<Account>(m, "Account")
        .def_property_readonly("position", &Account::position)
        .def_property_readonly("avg_entry_price", &Account::avg_entry_price)
        .def_property_readonly("cash", &Account::cash)
        .def_property_readonly("realized_pnl", &Account::realized_pnl, "Gross: before fees.")
        .def_property_readonly("fees_paid", &Account::fees_paid,
                               "Net of rebates; negative means rebates exceeded fees.")
        .def("unrealized_pnl", &Account::unrealized_pnl, py::arg("mark_price"))
        .def("net_pnl", &Account::net_pnl, py::arg("mark_price"),
             "realized + unrealized - fees.")
        .def_property_readonly("open_orders", &Account::open_orders,
                               "dict: order id -> OpenOrder (a copy).")
        .def_property_readonly("fills", &Account::fills, "list of FillRecord (a copy).")
        .def_property_readonly("orders_sent", &Account::orders_sent)
        .def_property_readonly("cancels_sent", &Account::cancels_sent)
        .def_property_readonly("rejects", &Account::rejects)
        .def_property_readonly("volume", &Account::volume);

    py::class_<LatencyLeg>(m, "LatencyLeg")
        .def(py::init([](uint64_t in_ns, uint64_t out_ns) { return LatencyLeg{in_ns, out_ns}; }),
             py::arg("in_ns") = 0, py::arg("out_ns") = 0)
        .def_readwrite("in_ns", &LatencyLeg::in_ns, "Exchange -> participant.")
        .def_readwrite("out_ns", &LatencyLeg::out_ns, "Participant -> exchange.");

    py::class_<LatencyProfile>(m, "LatencyProfile")
        .def(py::init<>())
        .def_readwrite("fallback", &LatencyProfile::fallback)
        .def_readwrite("compute_ns", &LatencyProfile::compute_ns)
        .def("leg", &LatencyProfile::leg, py::arg("exchange"))
        .def("set", &LatencyProfile::set, py::arg("exchange"), py::arg("leg"))
        .def_static("uniform", &LatencyProfile::uniform, py::arg("in_ns"), py::arg("out_ns"),
                    py::arg("compute_ns") = 0, "Same delay to every exchange.");

    py::enum_<LatencyTier>(m, "LatencyTier")
        .value("Retail", LatencyTier::Retail)
        .value("Direct", LatencyTier::Direct)
        .value("Colo", LatencyTier::Colo)
        .value("Microwave", LatencyTier::Microwave);

    m.def("latency_preset", &latency_preset, py::arg("tier"), py::arg("home") = 0,
          "Per-exchange latency table for a named tier; `home` is the co-located exchange.");
}

void bind_scheduler(py::module_& m) {
    py::enum_<ActionType>(m, "ActionType")
        .value("Add", ActionType::Add)
        .value("Market", ActionType::Market)
        .value("Cancel", ActionType::Cancel)
        .value("Reduce", ActionType::Reduce)
        .value("Replace", ActionType::Replace)
        .value("Wake", ActionType::Wake);

    py::class_<Action>(m, "Action")
        .def_readonly("type", &Action::type)
        .def_readonly("order", &Action::order)
        .def_readonly("target_order_id", &Action::target_order_id)
        .def_readonly("qty", &Action::qty)
        .def_static("add", &Action::add, py::arg("order"))
        .def_static("market", &Action::market, py::arg("order"))
        .def_static("cancel",
                    [](uint64_t order_id, const std::string& side) {
                        return Action::cancel(order_id, str_char(side));
                    },
                    py::arg("order_id"), py::arg("side") = "")
        .def_static("reduce",
                    [](uint64_t order_id, double qty, const std::string& side) {
                        return Action::reduce(order_id, qty, str_char(side));
                    },
                    py::arg("order_id"), py::arg("qty"), py::arg("side") = "")
        .def_static("replace", &Action::replace, py::arg("old_order_id"), py::arg("new_order"))
        .def_static("wake", &Action::wake);

    py::enum_<StepKind>(m, "StepKind")
        .value("BookAction", StepKind::BookAction)
        .value("Delivery", StepKind::Delivery);

    py::class_<StepResult>(m, "StepResult")
        .def_readonly("kind", &StepResult::kind)
        .def_readonly("time_ns", &StepResult::time_ns)
        .def_readonly("seq", &StepResult::seq)
        .def_readonly("participant", &StepResult::participant)
        .def_readonly("action", &StepResult::action)
        .def_readonly("events", &StepResult::events);

    // Subclass in Python and override the on_* callbacks. A subclass that
    // defines __init__ must call engine_sim.Participant.__init__(self).
    py::class_<Participant, PyParticipant>(m, "Participant")
        .def(py::init<>())
        .def("on_book_update", &Participant::on_book_update, py::arg("book"))
        .def("on_trade", &Participant::on_trade, py::arg("event"))
        .def("on_fill", &Participant::on_fill, py::arg("event"))
        .def("on_order_update", &Participant::on_order_update, py::arg("event"))
        .def("on_timer", &Participant::on_timer, py::arg("now_ns"))
        .def_property_readonly("id", &Participant::id)
        .def("send_limit",
             [](Participant& p, const std::string& side, double price, double size) {
                 return (p.*(&ParticipantAccess::send_limit))(str_char(side), price, size);
             },
             py::arg("side"), py::arg("price"), py::arg("size"),
             "Queue a limit order; returns its order id (0 if not registered).")
        .def("send_market",
             [](Participant& p, const std::string& side, double size) {
                 return (p.*(&ParticipantAccess::send_market))(str_char(side), size);
             },
             py::arg("side"), py::arg("size"),
             "Trade against the book now; any unfilled remainder is cancelled.")
        .def("cancel", static_cast<void (Participant::*)(uint64_t)>(&ParticipantAccess::cancel),
             py::arg("order_id"))
        .def("reduce",
             static_cast<void (Participant::*)(uint64_t, double)>(&ParticipantAccess::reduce),
             py::arg("order_id"), py::arg("qty"), "Partial cancel; keeps queue position.")
        .def("replace",
             static_cast<uint64_t (Participant::*)(uint64_t, double, double)>(
                 &ParticipantAccess::replace),
             py::arg("order_id"), py::arg("price"), py::arg("size"),
             "Cancel + re-enter at the back of the queue; returns the new order id.")
        .def("set_timer",
             static_cast<void (Participant::*)(uint64_t)>(&ParticipantAccess::set_timer),
             py::arg("delay_ns"))
        .def("now", static_cast<uint64_t (Participant::*)() const>(&ParticipantAccess::now))
        .def("queue_position",
             static_cast<std::optional<QueuePosition> (Participant::*)(uint64_t) const>(
                 &ParticipantAccess::queue_position),
             py::arg("order_id"))
        .def_property_readonly(
            "account",
            static_cast<const Account& (Participant::*)() const>(&ParticipantAccess::account),
            py::return_value_policy::reference);

    // step() / run() / run_until() keep the GIL: they call back into Python
    // participants.
    py::class_<Scheduler>(m, "Scheduler")
        .def(py::init<uint64_t>(), py::arg("seed") = 0)
        .def("add_participant", &Scheduler::add_participant, py::arg("id"),
             py::arg("participant"), py::arg("latency") = LatencyProfile{},
             py::keep_alive<1, 3>(), // the scheduler keeps the participant alive
             "Register a participant under a unique id.")
        .def("set_latency", &Scheduler::set_latency, py::arg("id"), py::arg("latency"))
        .def("is_registered", &Scheduler::is_registered, py::arg("id"))
        .def("account", &Scheduler::account, py::arg("id"),
             py::return_value_policy::reference_internal,
             "The account of a registered participant (IndexError otherwise).")
        .def("set_fees", &Scheduler::set_fees, py::arg("fees"))
        .def("set_book_depth", &Scheduler::set_book_depth, py::arg("levels"))
        .def("schedule", &Scheduler::schedule, py::arg("time_ns"), py::arg("source"),
             py::arg("action"),
             "Queue an action to hit the book at exactly time_ns (no latency, no account) "
             "-- for a data feed. Returns its sequence number.")
        .def("empty", &Scheduler::empty)
        .def_property_readonly("pending", &Scheduler::pending)
        .def_property_readonly("now", &Scheduler::now)
        .def_property_readonly("next_time", &Scheduler::next_time)
        .def("step",
             [](Scheduler& s) {
                 if (s.empty()) throw std::runtime_error("step() called on an empty scheduler");
                 return s.step();
             },
             "Process the earliest entry; returns a StepResult.")
        .def("run", &Scheduler::run, "Process entries until none are left; returns the count.")
        .def("run_until", &Scheduler::run_until, py::arg("time_ns"),
             "Process every entry due at or before time_ns; returns the count.")
        .def("open_inbox", &Scheduler::open_inbox, py::arg("id"))
        .def("drain_inbox", &Scheduler::drain_inbox, py::arg("id"))
        .def("record_events", &Scheduler::record_events, py::arg("on"))
        .def_property_readonly("event_log", &Scheduler::event_log,
                               "Every event so far (a copy; needs record_events(True)).")
        .def("set_snapshot_interval", &Scheduler::set_snapshot_interval, py::arg("interval_ns"))
        .def_property_readonly("snapshots", &Scheduler::snapshots)
        .def("restore", &Scheduler::restore, py::arg("snapshot"),
             "Load a snapshot's book and jump the clock to its time.")
        .def_property_readonly("book",
                               static_cast<OrderBook& (Scheduler::*)()>(&Scheduler::book),
                               py::return_value_policy::reference_internal)
        .def("random_u64", [](Scheduler& s) { return s.rng()(); },
             "Next value from the run's seeded random generator.");
}

} // namespace

PYBIND11_MODULE(engine_sim, m) {
    m.doc() = "C++ HFT matching engine and market simulation, exposed to Python";

    bind_market_types(m);
    bind_accounts_and_latency(m);
    bind_scheduler(m);

    py::class_<TradeRecord>(m, "TradeRecord")
        .def_readonly("timestamp_ns", &TradeRecord::timestamp_ns)
        .def_property_readonly("side", [](const TradeRecord& t) {
            return std::string(1, t.side);
        })
        .def_readonly("price", &TradeRecord::price)
        .def_readonly("size", &TradeRecord::size)
        .def_readonly("decision_latency_ns", &TradeRecord::decision_latency_ns)
        .def("__repr__", [](const TradeRecord& t) {
            return "<TradeRecord ts=" + std::to_string(t.timestamp_ns) +
                   " side=" + std::string(1, t.side) +
                   " price=" + std::to_string(t.price) +
                   " size=" + std::to_string(t.size) +
                   " decision_latency_ns=" + std::to_string(t.decision_latency_ns) + ">";
        });

    py::class_<PnLSnapshot>(m, "PnLSnapshot")
        .def_readonly("timestamp_ns", &PnLSnapshot::timestamp_ns)
        .def_readonly("realized_pnl", &PnLSnapshot::realized_pnl)
        .def_readonly("unrealized_pnl", &PnLSnapshot::unrealized_pnl)
        .def_readonly("position_size", &PnLSnapshot::position_size)
        .def_readonly("trade_count", &PnLSnapshot::trade_count)
        .def("__repr__", [](const PnLSnapshot& s) {
            return "<PnLSnapshot ts=" + std::to_string(s.timestamp_ns) +
                   " realized=" + std::to_string(s.realized_pnl) +
                   " unrealized=" + std::to_string(s.unrealized_pnl) +
                   " position=" + std::to_string(s.position_size) +
                   " trade_count=" + std::to_string(s.trade_count) + ">";
        });

    py::class_<SimulationResult>(m, "SimulationResult")
        .def_readonly("trades", &SimulationResult::trades)
        .def_readonly("pnl_curve", &SimulationResult::pnl_curve)
        .def_readonly("total_trades", &SimulationResult::total_trades)
        .def_readonly("compute_time_us", &SimulationResult::compute_time_us)
        .def_readonly("events", &SimulationResult::events,
                      "Order-lifecycle events; empty unless set_record_events(True).")
        .def_readonly("book_snapshots", &SimulationResult::book_snapshots,
                      "Periodic book snapshots; empty unless set_snapshot_interval(>0).");

    py::class_<OfflineSimulation>(m, "OfflineSimulation")
        .def(py::init<const std::string&>(), py::arg("file_path"),
             "Create a simulation that reads the packed binary MBO stream at file_path.")
        .def("run", &OfflineSimulation::run,
             // The hot loop is pure C++; release the GIL so other Python
             // threads can run while the simulation executes.
             py::call_guard<py::gil_scoped_release>(),
             "Execute the event loop and return a SimulationResult.")
        .def("set_player_latency", &OfflineSimulation::set_player_latency, py::arg("latency"),
             "Latency between the strategy and the exchange (default: none). Before run().")
        .def("set_fees", &OfflineSimulation::set_fees, py::arg("fees"),
             "Exchange fees applied to the strategy's fills (default: none). Before run().")
        .def("set_record_events", &OfflineSimulation::set_record_events, py::arg("on"),
             "Return the full event log in SimulationResult.events.")
        .def("set_snapshot_interval", &OfflineSimulation::set_snapshot_interval,
             py::arg("interval_ns"),
             "Keep a book snapshot every interval_ns of simulated time (0 = off).")
        .def_property_readonly("player_account", &OfflineSimulation::player_account,
                               py::return_value_policy::reference_internal,
                               "The strategy's account: position, PnL, fees, fill history.");

    // ---- Online (real-time) simulation ----
    // Not registered in Windows builds (CT_NO_ONLINE_SIM) -- see the #include
    // guard above.
#ifndef CT_NO_ONLINE_SIM
    py::class_<OnlineConfig>(m, "OnlineConfig")
        .def(py::init<>())
        .def_readwrite("file_path",      &OnlineConfig::file_path)
        .def_readwrite("itch_address",   &OnlineConfig::itch_address)
        .def_readwrite("itch_port",      &OnlineConfig::itch_port)
        .def_readwrite("ouch_port",      &OnlineConfig::ouch_port)
        .def_readwrite("time_scale",     &OnlineConfig::time_scale)
        .def_readwrite("stock_locate",   &OnlineConfig::stock_locate)
        .def_readwrite("enable_local_strategy",
                        &OnlineConfig::enable_local_strategy)
        .def_readwrite("auto_fill",      &OnlineConfig::auto_fill)
        .def_readwrite("session",        &OnlineConfig::session);

    py::class_<OnlineSimulation>(m, "OnlineSimulation")
        .def(py::init<const OnlineConfig&>(), py::arg("config"),
             "Create a real-time simulation from a config (which carries the MBO "
             "file_path to replay plus networking/pacing settings).")
        .def(py::init<const std::string&>(), py::arg("file_path"),
             "Convenience: create a real-time simulation reading the packed binary "
             "MBO stream at file_path with otherwise-default config.")
        .def("run",
             [](OnlineSimulation& self, py::object callback) {
                 // Wrap an optional Python callable as the C++ SampleCallback.
                 // The engine invokes it (on its market-data thread, with the
                 // GIL released) once per simulated second; we re-acquire the
                 // GIL here before touching Python.
                 // Capture the callable BY REFERENCE: it lives on this stack
                 // frame for the whole (synchronous) run() call, and the hook
                 // is only ever invoked during run(). This keeps the Python
                 // reference count owned here (under the GIL) instead of inside
                 // a C++ std::function that the engine may destroy while the
                 // GIL is released.
                 OnlineSimulation::SampleCallback hook;
                 if (!callback.is_none()) {
                     hook = [&callback](const PnLSnapshot& s, const L1State& l1) {
                         py::gil_scoped_acquire gil;
                         try {
                             callback(s.timestamp_ns, s.realized_pnl,
                                      s.unrealized_pnl, s.position_size,
                                      l1.best_bid, l1.best_ask, s.trade_count);
                         } catch (const py::error_already_set&) {
                             // Never let a Python exception unwind into C++.
                             PyErr_Clear();
                         }
                     };
                 }

                 // Release the GIL for the blocking run; the hook re-acquires
                 // it as needed. This keeps the asyncio event loop responsive.
                 py::gil_scoped_release release;
                 return self.run(std::move(hook));
             },
             py::arg("callback") = py::none(),
             "Broadcast ITCH market data in real time while serving OUCH order "
             "entry. If a callback is given, it is called once per simulated "
             "second as callback(timestamp_ns, realized_pnl, unrealized_pnl, "
             "position_size, best_bid, best_ask, trade_count). Returns a "
             "SimulationResult.")
        .def("stop", &OnlineSimulation::stop,
             // Just an atomic store (see OnlineSimulation::stop()); called from
             // a different thread than the one blocked in run(), so it must
             // not wait on anything run() might be holding. No GIL release
             // needed -- this returns immediately either way.
             "Request an early stop of an in-progress run() from another "
             "thread (e.g. a Stop button). run() unwinds through its normal "
             "cleanup path and returns whatever telemetry was collected so "
             "far. Safe to call at any time, including before run() starts "
             "or after it's already finished (no-op).")
        .def("set_ouch_observer",
             [](OnlineSimulation& self, py::object callback) {
                 if (callback.is_none()) {
                     self.set_ouch_observer(nullptr);
                     return;
                 }
                 // Capture BY VALUE (copies the py::object, incrementing its
                 // refcount) -- unlike run()'s by-reference hook, this one
                 // outlives the call that installs it: it's stored as a
                 // member (ouch_observer_) and fires later, on the OUCH
                 // thread, for as long as the engine runs. A by-reference
                 // capture would dangle the moment set_ouch_observer()
                 // returns.
                 self.set_ouch_observer(
                     [callback](const protocol::OuchMessage& msg, const uint8_t* raw, size_t len) {
                         py::gil_scoped_acquire gil;
                         try {
                             callback(std::string(1, msg.msg_type ? msg.msg_type : '?'),
                                      msg.order_id,
                                      std::string(1, msg.side ? msg.side : '-'),
                                      msg.price, msg.size, msg.ticker,
                                      py::bytes(reinterpret_cast<const char*>(raw), len));
                         } catch (const py::error_already_set&) {
                             PyErr_Clear();
                         }
                     });
             },
             py::arg("callback"),
             "Set an observer invoked for every inbound OUCH message (real "
             "FPGA or a test client), called as callback(msg_type, order_id, "
             "side, price, size, ticker, raw_bytes) -- ticker is '' for "
             "OUCH Cancel (no symbol on that wire format) or if the sender "
             "left it blank. Must be set before run() -- it fires on the "
             "engine's OUCH thread. Pass None to clear it.")
        .def("set_trade_observer",
             [](OnlineSimulation& self, py::object callback) {
                 if (callback.is_none()) {
                     self.set_trade_observer(nullptr);
                     return;
                 }
                 // By value, same reasoning as set_ouch_observer above: this
                 // outlives the call that installs it (stored as a member,
                 // fires later on whichever thread produces a fill).
                 self.set_trade_observer(
                     [callback](const TradeRecord& t) {
                         py::gil_scoped_acquire gil;
                         try {
                             callback(t.timestamp_ns, std::string(1, t.side),
                                      t.price, t.size, t.decision_latency_ns);
                         } catch (const py::error_already_set&) {
                             PyErr_Clear();
                         }
                     });
             },
             py::arg("callback"),
             "Set an observer invoked for every trade fill as it happens -- "
             "the loopback local strategy or a real inbound OUCH order -- "
             "called as callback(timestamp_ns, side, price, size, "
             "decision_latency_ns). decision_latency_ns is 0 for "
             "OUCH-originated fills (not measured; see TradeRecord). Must be "
             "set before run() -- it fires on whichever thread produced the "
             "fill. Pass None to clear it.");
#endif  // CT_NO_ONLINE_SIM
}
