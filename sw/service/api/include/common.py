"""Shared API schemas used across requests and responses."""

from typing import List, Optional, TypeVar

from pydantic import BaseModel

T = TypeVar("T")


def apply_limit(items: List[T], limit: Optional[int]) -> List[T]:
    """Cap a list to its first `limit` items, or return it unchanged if
    `limit` is None. Shared by every endpoint that trims trades/pnl_curve
    for the response while persisting the untrimmed data to the DB."""
    return items[:limit] if limit is not None else items


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
