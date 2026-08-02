import React from "react";
import { BrowserRouter, NavLink, Route, Routes } from "react-router-dom";
import OnlineDemoPage from "./pages/OnlineDemoPage.jsx";
import StrategyCompilerPage from "./pages/StrategyCompilerPage.jsx";

function TopNav() {
    return (
        <nav className="top-nav">
            <NavLink to="/" end className={({ isActive }) => (isActive ? "active" : "")}>
                Online Simulation
            </NavLink>
            <NavLink to="/strategy-compiler" className={({ isActive }) => (isActive ? "active" : "")}>
                Strategy Compiler
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
                </Routes>
            </div>
        </BrowserRouter>
    );
}
