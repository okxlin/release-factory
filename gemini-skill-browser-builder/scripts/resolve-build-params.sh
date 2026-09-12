#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec python3 "$ROOT/gemini-skill-browser-builder/scripts/resolve-browser-inputs.py" --variant kasm "$@"
