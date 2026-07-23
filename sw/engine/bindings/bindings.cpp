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
        .def_readonly("compute_time_ms", &SimulationResult::compute_time_ms);

    py::class_<OfflineSimulation>(m, "OfflineSimulation")
        .def(py::init<const std::string&>(), py::arg("file_path"),
             "Create a simulation that reads the packed binary MBO stream at file_path.")
        .def("run", &OfflineSimulation::run,
             // The hot loop is pure C++; release the GIL so other Python
             // threads can run while the simulation executes.
             py::call_guard<py::gil_scoped_release>(),
             "Execute the event loop and return a SimulationResult.");
}
