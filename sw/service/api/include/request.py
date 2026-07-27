"""Request schemas for the HFT engine service."""

from typing import Optional

from pydantic import BaseModel, Field


class SimulationRequest(BaseModel):
    """Parameters for a simulation run."""

    data_file: Optional[str] = Field(
        default=None,
        description=(
            "Path to the packed binary MBO stream (.bin). May be absolute or "
            "relative to the service directory. Defaults to the bundled "
            "synthetic_mbo_stream.bin."
        ),
    )
    trade_limit: Optional[int] = Field(
        default=None,
        ge=0,
        description="Cap the number of trade records returned. None = all.",
    )
    pnl_limit: Optional[int] = Field(
        default=None,
        ge=0,
        description="Cap the number of PnL snapshots returned. None = all.",
    )


class OnlineSimulationRequest(SimulationRequest):
    """Parameters for a real-time (online) simulation run.

    Note: the online engine's market-data (ITCH/UDP) and order-entry
    (OUCH/TCP) sockets are internal server-side transport and are never
    exposed here. Clients only choose the data file, optional pacing, and
    output limits.
    """

    time_scale: Optional[float] = Field(
        default=None,
        ge=0.0,
        description=(
            "Wall-clock pacing factor for the replay. 0.0 = no pacing (fastest, "
            "the call returns as soon as the stream is processed); 1.0 = true "
            "real time; 0.001 = 1000x faster. Defaults to the server setting."
        ),
    )
