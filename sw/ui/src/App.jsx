import React from "react";
import { BrowserRouter, NavLink, Route, Routes } from "react-router-dom";
import OnlineDemoPage from "./pages/OnlineDemoPage.jsx";
import StrategyCompilerPage from "./pages/StrategyCompilerPage.jsx";
import AlphaEngineCompilerPage from "./pages/AlphaEngineCompilerPage.jsx";

function TopNav() {
    return (
        <nav className="top-nav">
            <NavLink to="/" end className={({ isActive }) => (isActive ? "active" : "")}>
                Online Simulation
            </NavLink>
            <NavLink to="/strategy-compiler" className={({ isActive }) => (isActive ? "active" : "")}>
                Strategy Compiler
            </NavLink>
            <NavLink to="/alpha-engine-compiler" className={({ isActive }) => (isActive ? "active" : "")}>
                Alpha Engine Compiler
            </NavLink>
        </nav>
    );
}

export default function App() {
    return (
        <BrowserRouter>
            <div className="app">
                <TopNav />
                <Routes>
                    <Route path="/" element={<OnlineDemoPage />} />
                    <Route path="/strategy-compiler" element={<StrategyCompilerPage />} />
                    <Route path="/alpha-engine-compiler" element={<AlphaEngineCompilerPage />} />
                </Routes>
            </div>
        </BrowserRouter>
    );
}
