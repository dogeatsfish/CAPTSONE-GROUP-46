// Pybind11 bindings exposing the C++ offline simulation to Python.
//
// Build produces an importable module named `engine_sim`. Example usage:
//
//     import engine_sim
//     sim = engine_sim.OfflineSimulation("data/synthetic_mbo_stream.bin")
//     result = sim.run()
//     print(result.total_trades, result.compute_time_ms)
//     for t in result.trades[:5]:
//         print(t.timestamp_ns, t.side, t.price, t.size)

#include <pybind11/pybind11.h>
#include <pybind11/stl.h>       // automatic std::vector <-> list conversion

#include "offline_simulation.h"
// OnlineSimulation uses POSIX sockets and isn't buildable on native Windows
// yet (see the Windows branch of the pymodule target in engine/Makefile,
// which defines CT_NO_ONLINE_SIM). macOS/Linux builds are unaffected.
#ifndef CT_NO_ONLINE_SIM
#include "online_simulation.h"
#endif

namespace py = pybind11;

PYBIND11_MODULE(engine_sim, m) {
    m.doc() = "C++ HFT matching-engine offline simulation, exposed to Python";

    py::class_<TradeRecord>(m, "TradeRecord")
        .def_readonly("timestamp_ns", &TradeRecord::timestamp_ns)
        .def_property_readonly("side", [](const TradeRecord& t) {
            return std::string(1, t.side);
        })
        .def_readonly("price", &TradeRecord::price)
        .def_readonly("size", &TradeRecord::size)
        .def("__repr__", [](const TradeRecord& t) {
            return "<TradeRecord ts=" + std::to_string(t.timestamp_ns) +
                   " side=" + std::string(1, t.side) +
                   " price=" + std::to_string(t.price) +
                   " size=" + std::to_string(t.size) + ">";
        });

    py::class_<PnLSnapshot>(m, "PnLSnapshot")
        .def_readonly("timestamp_ns", &PnLSnapshot::timestamp_ns)
        .def_readonly("realized_pnl", &PnLSnapshot::realized_pnl)
        .def_readonly("unrealized_pnl", &PnLSnapshot::unrealized_pnl)
        .def_readonly("position_size", &PnLSnapshot::position_size)
        .def("__repr__", [](const PnLSnapshot& s) {
            return "<PnLSnapshot ts=" + std::to_string(s.timestamp_ns) +
                   " realized=" + std::to_string(s.realized_pnl) +
                   " unrealized=" + std::to_string(s.unrealized_pnl) +
                   " position=" + std::to_string(s.position_size) + ">";
        });

    py::class_<SimulationResult>(m, "SimulationResult")
        .def_readonly("trades", &SimulationResult::trades)
        .def_readonly("pnl_curve", &SimulationResult::pnl_curve)
        .def_readonly("total_trades", &SimulationResult::total_trades)
        .def_readonly("compute_time_us", &SimulationResult::compute_time_us);

    py::class_<OfflineSimulation>(m, "OfflineSimulation")
        .def(py::init<const std::string&>(), py::arg("file_path"),
             "Create a simulation that reads the packed binary MBO stream at file_path.")
        .def("run", &OfflineSimulation::run,
             // The hot loop is pure C++; release the GIL so other Python
             // threads can run while the simulation executes.
             py::call_guard<py::gil_scoped_release>(),
             "Execute the event loop and return a SimulationResult.");

    // ---- Online (real-time) simulation ----
    // Not registered in Windows builds (CT_NO_ONLINE_SIM) -- see the #include
    // guard above.
#ifndef CT_NO_ONLINE_SIM
    py::enum_<OnlineSimulation::OuchTransport>(m, "OuchTransport")
        .value("UDP", OnlineSimulation::OuchTransport::UDP)
        .value("TCP", OnlineSimulation::OuchTransport::TCP);

    py::class_<OnlineSimulation::Config>(m, "OnlineConfig")
        .def(py::init<>())
        .def_readwrite("itch_address",   &OnlineSimulation::Config::itch_address)
        .def_readwrite("itch_port",      &OnlineSimulation::Config::itch_port)
        .def_readwrite("ouch_port",      &OnlineSimulation::Config::ouch_port)
        .def_readwrite("ouch_transport", &OnlineSimulation::Config::ouch_transport)
        .def_readwrite("time_scale",     &OnlineSimulation::Config::time_scale)
        .def_readwrite("max_sleep_ns",   &OnlineSimulation::Config::max_sleep_ns)
        .def_readwrite("stock_locate",   &OnlineSimulation::Config::stock_locate);

    py::class_<OnlineSimulation>(m, "OnlineSimulation")
        .def(py::init<const std::string&>(), py::arg("file_path"),
             "Create a real-time simulation reading the packed binary MBO stream "
             "at file_path (default networking config).")
        .def(py::init<const std::string&, const OnlineSimulation::Config&>(),
             py::arg("file_path"), py::arg("config"),
             "Create a real-time simulation with an explicit networking/pacing config.")
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
                                      l1.best_bid, l1.best_ask);
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
             "position_size, best_bid, best_ask). Returns a SimulationResult.")
        .def("stop", &OnlineSimulation::stop,
             // Just an atomic store (see OnlineSimulation::stop()); called from
             // a different thread than the one blocked in run(), so it must
             // not wait on anything run() might be holding. No GIL release
             // needed -- this returns immediately either way.
             "Request an early stop of an in-progress run() from another "
             "thread (e.g. a Stop button). run() unwinds through its normal "
             "cleanup path and returns whatever telemetry was collected so "
             "far. Safe to call at any time, including before run() starts "
             "or after it's already finished (no-op).");
#endif  // CT_NO_ONLINE_SIM
}
