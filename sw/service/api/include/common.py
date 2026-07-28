"""Shared API schemas used across requests and responses."""

from pydantic import BaseModel


class Trade(BaseModel):
    timestamp_ns: int
    side: str
    price: float
    size: float


class PnLPoint(BaseModel):
    timestamp_ns: int
    realized_pnl: float
    unrealized_pnl: float
    position_size: float
