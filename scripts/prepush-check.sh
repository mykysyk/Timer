#!/usr/bin/env bash
set -euo pipefail

# push前に最低限の品質ゲートを実行する
# すべてDocker内で実行するため、ホストにFlutter SDKは不要

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_ROOT"

echo "[1/2] flutter analyze"
"$SCRIPT_DIR/flutter.sh" analyze

echo "[2/2] flutter test"
"$SCRIPT_DIR/flutter.sh" test

echo "prepush-check: OK"
