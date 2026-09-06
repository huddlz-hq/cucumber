#!/bin/bash
# Read-only source checks shared by CI and releases. Build outputs are expected.
set -euo pipefail
cd "$(dirname "$0")/.."

export MIX_ENV=test
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict
mix test
mix hex.audit

export MIX_ENV=dev
mix compile --warnings-as-errors
mix docs --warnings-as-errors
mix hex.build
