#!/usr/bin/env bash
set -euo pipefail

# ホストを汚さず、Git 操作も Docker コンテナ内で実行するスクリプト
# -u で UID/GID を合わせて、権限問題を防ぐ
# 必要に応じて .ssh を読み取り専用で渡す

if [ "$#" -eq 0 ]; then
  echo "使い方: ./scripts/git.sh <git-subcommand>"
  echo "例: ./scripts/git.sh status"
  echo "例: ./scripts/git.sh push origin main"
  exit 1
fi

UID_GID="$(id -u):$(id -g)"
EXTRA_ARGS=("--rm" "-u" "$UID_GID")
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

# git の global 設定保存先を、ホストの書き込み可能ディレクトリに固定する
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GIT_HOME_HOST="$PROJECT_ROOT/.codex-git-home"
mkdir -p "$GIT_HOME_HOST"
mkdir -p "$GIT_HOME_HOST/.ssh"

EXTRA_ARGS+=("-v" "$GIT_HOME_HOST:/tmp/codex-home")
EXTRA_ARGS+=("-v" "/etc/passwd:/etc/passwd:ro")
EXTRA_ARGS+=("-v" "/etc/group:/etc/group:ro")

if [ -d "$HOME/.ssh" ]; then
  EXTRA_ARGS+=("-v" "$HOME/.ssh:/tmp/host-ssh:ro")
fi

EXTRA_ARGS+=("-e" "HOME=/tmp/codex-home")
EXTRA_ARGS+=("-e" "GIT_SSH_COMMAND=ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/tmp/codex-home/.ssh/known_hosts -o IdentitiesOnly=yes -o IdentityFile=/tmp/codex-home/.ssh/id_ed25519 -o IdentityFile=/tmp/host-ssh/id_ed25519 -o IdentityFile=/tmp/host-ssh/id_rsa -o IdentityFile=/tmp/host-ssh/id_ecdsa")

exec "${COMPOSE_CMD[@]}" run "${EXTRA_ARGS[@]}" flutter git -c safe.directory=/workspace "$@"
