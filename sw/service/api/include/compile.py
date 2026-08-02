"""Request/response schemas for the Alpha Engine compile-and-report endpoint."""

from pydantic import BaseModel, Field


class CompileRequest(BaseModel):
    """A user's Alpha Engine Core submission."""

    source: str = Field(
        description="Raw SystemVerilog source for the alpha_engine_core module."
    )
    module_name: str = Field(
        default="alpha_engine_core",
        description=(
            "Name of the top-level module to synthesize. Fixed for now since "
            "only one sandbox module (FS-8) exists; kept explicit so a future "
            "mismatch fails loudly instead of silently synthesizing the wrong "
            "module."
        ),
    )


class CompileStartResponse(BaseModel):
    """Returned by the POST that starts a compile job.

    The client then opens an EventSource (SSE) against ``stream_url`` to
    receive live log lines and the final pass/fail result.
    """

    job_id: str
    stream_url: str
