#!/usr/bin/env bash
set -euo pipefail

# ホストに Flutter を入れず、必ず Docker コンテナ内で実行する
if [ "$#" -eq 0 ]; then
  echo "使い方: ./scripts/flutter.sh <flutter-subcommand>"
  echo "例: ./scripts/flutter.sh pub get"
  exit 1
fi

COMPOSE_CMD=()

# docker compose / docker-compose のどちらでも動くようにする
if docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD=("docker" "compose")
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_CMD=("docker-compose")
else
  echo "docker compose か docker-compose が見つかりません。"
  exit 1
fi

exec "${COMPOSE_CMD[@]}" run --rm flutter flutter "$@"
