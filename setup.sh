#!/usr/bin/env bash
# Wrapper script to execute scripts/setup-lab-k3d.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/scripts/setup-lab-k3d.sh" "$@"
