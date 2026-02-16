#!/usr/bin/env bash
set -euo pipefail

# multi-git-add-commit-push.sh
#
# Делает в каждом репозитории из списка:
#   1) checkout/создание ветки BRANCH (если нет — создаёт от default ветки origin/HEAD)
#   2) git add <ADD_ARGS...>
#   3) git commit -m "<COMMIT_MESSAGE>" (если есть staged изменения)
#   4) git push -u origin <BRANCH>
#
# Usage:
#   ./multi-git-add-commit-push.sh /abs/path/repos.txt branch_name "commit message" -- <git add args...>
#
# Example:
#   ./multi-git-add-commit-push.sh /abs/repos.txt feature/foo "update configs" -- -A
#   ./multi-git-add-commit-push.sh /abs/repos.txt feature/foo "add files" -- src/ README.md

usage() {
  cat <<'EOF'
Usage:
  multi-git-add-commit-push.sh /abs/path/repos.txt branch_name "commit message" -- <git add args...>

Notes:
  - Все аргументы после `--` будут переданы в `git add`.
  - Ветка создаётся от default-ветки origin/HEAD (обычно main или master), если её нет локально и на origin.
EOF
}

log() { printf "\n[%s] %s\n" "$(date +'%F %T')" "$*"; }
warn(){ printf "[WARN] %s\n" "$*" >&2; }

if [[ $# -lt 5 ]]; then
  usage
  exit 1
fi

LIST_FILE="$1"
BRANCH="$2"
COMMIT_MSG="$3"
SEP="$4"
shift 4

if [[ "$SEP" != "--" ]]; then
  warn "Missing -- separator before git add args"
  usage
  exit 1
fi

if [[ ! -f "$LIST_FILE" ]]; then
  warn "No such file: $LIST_FILE"
  exit 1
fi

if [[ -z "$BRANCH" ]]; then
  warn "Branch name is empty"
  exit 1
fi

if [[ -z "$COMMIT_MSG" ]]; then
  warn "Commit message is empty"
  exit 1
fi

if [[ $# -lt 1 ]]; then
  warn "You must pass arguments for git add after --"
  exit 1
fi

ADD_ARGS=( "$@" )

get_default_branch() {
  # Пытаемся взять origin/HEAD -> refs/remotes/origin/<name>
  local headref=""
  headref="$(git symbolic-ref -q "refs/remotes/origin/HEAD" 2>/dev/null || true)"
  if [[ -n "$headref" ]]; then
    echo "${headref##*/}"
    return 0
  fi

  # Фоллбеки
  if git show-ref --verify --quiet refs/heads/main; then echo "main"; return 0; fi
  if git show-ref --verify --quiet refs/heads/master; then echo "master"; return 0; fi
  if git show-ref --verify --quiet refs/remotes/origin/main; then echo "main"; return 0; fi
  if git show-ref --verify --quiet refs/remotes/origin/master; then echo "master"; return 0; fi

  echo "master"
}

checkout_or_create_branch() {
  local target="$1"
  local base="$2"

  # Если уже на нужной ветке — ок
  local cur=""
  cur="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [[ "$cur" == "$target" ]]; then
    return 0
  fi

  # Если есть локальная ветка — переключаемся
  if git show-ref --verify --quiet "refs/heads/${target}"; then
    git switch "$target" >/dev/null
    return 0
  fi

  # Если есть удалённая ветка — создаём tracking локальную
  if git show-ref --verify --quiet "refs/remotes/origin/${target}"; then
    git switch -c "$target" --track "origin/${target}" >/dev/null
    return 0
  fi

  # Иначе создаём новую от base (tracking base если нужно)
  if git show-ref --verify --quiet "refs/heads/${base}"; then
    git switch "$base" >/dev/null
  elif git show-ref --verify --quiet "refs/remotes/origin/${base}"; then
    git switch -c "$base" --track "origin/${base}" >/dev/null
  else
    # Совсем странный случай: base не найден — остаёмся на текущем HEAD
    :
  fi

  git switch -c "$target" >/dev/null
}

process_repo() {
  local repo="$1"

  [[ -z "$repo" || "$repo" =~ ^[[:space:]]*# ]] && return 0

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

  # Проверим origin
  if ! git remote get-url origin >/dev/null 2>&1; then
    warn "  SKIP (no remote 'origin'): $repo"
    return 0
  fi

  # Обновим refs
  git fetch origin --prune >/dev/null || true

  local base
  base="$(get_default_branch)"

  # Перейти/создать ветку
  checkout_or_create_branch "$BRANCH" "$base"

  # Stage
  git add "${ADD_ARGS[@]}"

  # Commit (только если есть staged изменения)
  if git diff --cached --quiet; then
    log "  Nothing staged -> skip commit"
  else
    git commit -m "$COMMIT_MSG" >/dev/null
    log "  Committed"
  fi

  # Push (создаст ветку на origin, если её там нет)
  git push -u origin "$BRANCH" >/dev/null
  log "  Pushed: origin/$BRANCH"
}

# main loop: продолжаем даже если в одном репо ошибка
while IFS= read -r repo || [[ -n "$repo" ]]; do
  (
    process_repo "$repo"
  ) || warn "FAILED: $repo"
done < "$LIST_FILE"

log "Done."
