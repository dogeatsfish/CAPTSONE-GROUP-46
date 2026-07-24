"""Project paths and heavy imports for the API.

Centralizes all filesystem wiring so the route handlers stay focused on
request/response logic. Importing this module has two intentional side effects:

  * puts the schema modules (api/include) on sys.path, so `import common` works
  * puts the compiled C++ engine (engine/) on sys.path and imports `engine_sim`

Both make plain imports work no matter which directory uvicorn is launched from.
"""

import sys
from pathlib import Path

# --- Directory layout (this file lives in service/api/config) ---
CONFIG_DIR = Path(__file__).resolve().parent  # service/api/config
API_DIR = CONFIG_DIR.parent  # service/api
INCLUDE_DIR = API_DIR / "include"  # service/api/include
SERVICE_ROOT = API_DIR.parent  # service
REPO_ROOT = SERVICE_ROOT.parent  # sw
ENGINE_DIR = REPO_ROOT / "engine"
DATA_DIR = REPO_ROOT / "data_pipeline" / "data"
DEFAULT_DATA_FILE = DATA_DIR / "synthetic_mbo_stream.bin"

# Make the schema modules and the compiled engine importable.
for _path in (INCLUDE_DIR, ENGINE_DIR):
    if str(_path) not in sys.path:
        sys.path.insert(0, str(_path))

try:
    import engine_sim  # re-exported for the routes to use
except ImportError as exc:  # pragma: no cover - build/environment issue
    raise ImportError(
        f"Could not import the compiled 'engine_sim' module from {ENGINE_DIR}. "
        "Build it first: run `make pymodule` in the engine/ directory."
    ) from exc
