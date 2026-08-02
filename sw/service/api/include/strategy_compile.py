"""Request/response schemas for the software strategy compile-and-run endpoint."""

from pydantic import BaseModel, Field

from request import SimulationRequest


class StrategyCompileRequest(SimulationRequest):
    """A user's on_market_update submission, plus what to run it against.

    data_file/trade_limit/pnl_limit are inherited from SimulationRequest
    unchanged -- this endpoint runs the same kind of simulation as /simulate,
    just against a freshly compiled strategy instead of the baked-in one.
    """

    on_market_update_body: str = Field(
        description="C++ statements for the body of Strategy::on_market_update."
    )


class StrategyCompileStartResponse(BaseModel):
    """Returned by the POST that starts a software strategy compile job.

    The client then opens an EventSource (SSE) against ``stream_url`` to
    receive live compiler/run log lines and the final result.
    """

    job_id: str
    stream_url: str
