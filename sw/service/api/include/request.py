"""Request schemas for the HFT engine service."""

from typing import Literal, Optional

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
    online_target: Literal["loopback", "hardware"] = Field(
        default="loopback",
        description=(
            "Only meaningful for /simulate/online/stream. 'loopback' (default) "
            "is a software-only live view -- fast, no board needed. 'hardware' "
            "targets the real FPGA at the configured board address, paced in "
            "real time to match it. Ignored by every other endpoint."
        ),
    )
