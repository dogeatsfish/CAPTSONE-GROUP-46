"""FastAPI application entry point.

Wires up the API by mounting the routers defined in ``routes.py``. Run from
the ``service/api/src`` directory:

    uvicorn app:app --reload
    ../../.venv/bin/uvicorn app:app --reload

The heavy lifting (running the C++ offline simulation via the ``engine_sim``
pybind11 module) lives in ``routes.py``.
"""

import os
import sys

# Ensure this directory is importable so `import routes` works regardless of
# the current working directory uvicorn is launched from.
_SRC_DIR = os.path.dirname(os.path.abspath(__file__))
if _SRC_DIR not in sys.path:
    sys.path.insert(0, _SRC_DIR)

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from routes import router

app = FastAPI(
    title="HFT Engine Service",
    description="HTTP API around the C++ offline matching-engine simulation.",
    version="0.1.0",
)

# Allow the local UI (and other dev origins) to call the API from the browser.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Mount the endpoints defined in routes.py.
app.include_router(router)


@app.get("/", tags=["health"])
def root():
    """Basic liveness probe."""
    return {"status": "ok", "service": "hft-engine-service"}
