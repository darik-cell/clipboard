#!/usr/bin/env bash
set -euo pipefail

# multi-git-branch.sh
# Для каждого репозитория из списка:
#   - delete-local   : удалить ветку локально
#   - delete-remote  : удалить ветку только на origin
#   - delete-both    : удалить локально + на origin
#   - create         : создать ветку от default-ветки (master/main/remote HEAD)
#   - checkout       : переключиться на ветку (локальную или remote tracking)
#
# Usage:
#   ./multi-git-branch.sh /abs/path/repos.txt branch_name ACTION [options]
#
# Options:
#   --remote NAME        remote name (default: origin)
#   --no-fetch           не делать fetch перед операциями
#   --pull               делать pull --ff-only на default-ветке (для create)
#   --clean-reset        ЖЕСТКО: сбросить локальные изменения (reset --hard + clean -fd) перед действиями
#   --push               (для create) запушить ветку и установить upstream
#   --keep-going         продолжать при ошибках (default)
#   --stop-on-error      остановиться на первой ошибке

REMOTE="origin"
DO_FETCH=1
DO_PULL=0
CLEAN_RESET=0
DO_PUSH=0
KEEP_GOING=1

usage() {
  cat <<EOF
Usage:
  $0 /abs/path/repos.txt branch_name ACTION [options]

ACTION:
  delete-local | delete-remote | delete-both | create | checkout

Options:
  --remote NAME
  --no-fetch
  --pull
  --clean-reset
  --push
  --keep-going
  --stop-on-error

Examples:
  $0 /abs/repos.txt feature/foo delete-both
  $0 /abs/repos.txt feature/foo delete-remote
  $0 /abs/repos.txt feature/foo create --pull --push
  $0 /abs/repos.txt feature/foo checkout
EOF
}

log() { printf "\n[%s] %s\n" "$(date +'%F %T')" "$*"; }
warn(){ printf "[WARN] %s\n" "$*" >&2; }
err() { printf "[ERR ] %s\n" "$*" >&2; }

if [[ $# -lt 3 ]]; then
  usage
  exit 1
fi

LIST_FILE="$1"
BRANCH="$2"
ACTION="$3"
shift 3

if [[ ! -f "$LIST_FILE" ]]; then
  err "No such file: $LIST_FILE"
  exit 1
fi

case "$ACTION" in
  delete-local|delete-remote|delete-both|create|checkout) ;;
  *) err "Unknown ACTION: $ACTION"; usage; exit 1 ;;
esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote) REMOTE="${2:-}"; shift 2 ;;
    --no-fetch) DO_FETCH=0; shift ;;
    --pull) DO_PULL=1; shift ;;
    --clean-reset) CLEAN_RESET=1; shift ;;
    --push) DO_PUSH=1; shift ;;
    --keep-going) KEEP_GOING=1; shift ;;
    --stop-on-error) KEEP_GOING=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown option: $1"; usage; exit 1 ;;
  esac
done

get_default_branch() {
  # 1) Попробовать origin/HEAD
  local headref=""
  headref="$(git symbolic-ref -q "refs/remotes/${REMOTE}/HEAD" 2>/dev/null || true)"
  if [[ -n "$headref" ]]; then
    echo "${headref##*/}"
    return 0
  fi

  # 2) Если локально есть master/main
  if git show-ref --verify --quiet refs/heads/master; then echo "master"; return 0; fi
  if git show-ref --verify --quiet refs/heads/main; then echo "main"; return 0; fi

  # 3) Если есть удалённые master/main
  if git show-ref --verify --quiet "refs/remotes/${REMOTE}/master"; then echo "master"; return 0; fi
  if git show-ref --verify --quiet "refs/remotes/${REMOTE}/main"; then echo "main"; return 0; fi

  # 4) Фоллбек
  echo "master"
}

ensure_on_branch() {
  local base="$1"

  # Создать/обновить локальную base, если есть remote
  if git show-ref --verify --quiet "refs/heads/${base}"; then
    git switch "$base" >/dev/null
  elif git show-ref --verify --quiet "refs/remotes/${REMOTE}/${base}"; then
    git switch -c "$base" --track "${REMOTE}/${base}" >/dev/null
  else
    # base не существует ни локально, ни на remote: просто попробуем создать
    git switch -c "$base" >/dev/null
  fi
}

has_dirty_worktree() {
  # true если есть изменения/неотслеживаемые файлы
  ! git diff --quiet || ! git diff --cached --quiet || [[ -n "$(git status --porcelain)" ]]
}

delete_local_branch() {
  local b="$1"
  if git show-ref --verify --quiet "refs/heads/${b}"; then
    git branch -D "$b" >/dev/null
    log "  Deleted local: $b"
  else
    log "  Local branch not found: $b"
  fi
}

delete_remote_branch() {
  local b="$1"
  # Проверим, есть ли ветка на remote
  if git ls-remote --heads "$REMOTE" "$b" | grep -q .; then
    git push "$REMOTE" --delete "$b" >/dev/null
    log "  Deleted remote: ${REMOTE}/${b}"
  else
    log "  Remote branch not found: ${REMOTE}/${b}"
  fi
}

create_branch_from_base() {
  local b="$1"
  local base="$2"

  if git show-ref --verify --quiet "refs/heads/${b}"; then
    log "  Branch already exists locally: $b (skip)"
    return 0
  fi

  # Создаём от текущего HEAD (мы уже на base)
  git switch -c "$b" >/dev/null
  log "  Created branch: $b (from $base)"

  if [[ "$DO_PUSH" -eq 1 ]]; then
    git push -u "$REMOTE" "$b" >/dev/null
    log "  Pushed and set upstream: ${REMOTE}/${b}"
  fi
}

checkout_branch() {
  local b="$1"
  local cur=""

  cur="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [[ "$cur" == "$b" ]]; then
    log "  Already on branch: $b"
    return 0
  fi

  if git show-ref --verify --quiet "refs/heads/${b}"; then
    git switch "$b" >/dev/null
    log "  Checked out local: $b"
    return 0
  fi

  if git show-ref --verify --quiet "refs/remotes/${REMOTE}/${b}"; then
    git switch -c "$b" --track "${REMOTE}/${b}" >/dev/null
    log "  Checked out and tracking: ${REMOTE}/${b}"
    return 0
  fi

  warn "  Branch not found locally or on ${REMOTE}: $b (skip)"
}

process_repo() {
  local repo="$1"

  if [[ ! "$repo" = /* ]]; then
    warn "SKIP (not absolute path): $repo"
    return 0
  fi
  if [[ ! -d "$repo" ]]; then
    warn "SKIP (no such dir): $repo"
    return 0
  fi
  if [[ ! -d "$repo/.git" ]]; then
    warn "SKIP (not a git repo): $repo"
    return 0
  fi

  log "Repo: $repo"
  cd "$repo"

  if [[ "$DO_FETCH" -eq 1 ]]; then
    git fetch "$REMOTE" --prune >/dev/null || git fetch --prune >/dev/null
  fi

  if [[ "$CLEAN_RESET" -eq 1 ]]; then
    git reset --hard >/dev/null
    git clean -fd >/dev/null
  else
    if has_dirty_worktree; then
      warn "  Dirty working tree. Use --clean-reset to discard changes. (skip repo)"
      return 0
    fi
  fi

  local base=""
  if [[ "$ACTION" == "delete-local" || "$ACTION" == "delete-both" || "$ACTION" == "create" ]]; then
    base="$(get_default_branch)"

    # Для delete-local/delete-both: если удаляем текущую ветку — сперва уйти на base
    # Для create: тоже переходим на base
    ensure_on_branch "$base"

    if [[ "$DO_PULL" -eq 1 ]]; then
      # Обновляем base строго fast-forward
      git pull --ff-only "$REMOTE" "$base" >/dev/null || true
    fi
  fi

  case "$ACTION" in
    delete-local)
      # если сейчас на BRANCH — ensure_on_branch уже увёл на base
      delete_local_branch "$BRANCH"
      ;;
    delete-remote)
      delete_remote_branch "$BRANCH"
      ;;
    delete-both)
      delete_remote_branch "$BRANCH"
      delete_local_branch "$BRANCH"
      ;;
    create)
      # Создать ветку от base (обычно master/main/remote HEAD)
      create_branch_from_base "$BRANCH" "$base"
      ;;
    checkout)
      checkout_branch "$BRANCH"
      ;;
  esac
}

# main loop
while IFS= read -r repo || [[ -n "$repo" ]]; do
  # пропустить пустые строки и комментарии
  [[ -z "$repo" || "$repo" =~ ^[[:space:]]*# ]] && continue

  if [[ "$KEEP_GOING" -eq 1 ]]; then
    ( process_repo "$repo" ) || warn "FAILED: $repo"
  else
    process_repo "$repo"
  fi
done < "$LIST_FILE"

log "Done."
