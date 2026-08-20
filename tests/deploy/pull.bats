#!/usr/bin/env bats
# Behavioral tests for deploy/00-pull.sh in a scratch git repo with a bare
# "origin" — .env parsing, fetch/merge recovery, .last-deployed resume, and
# the configs/data-only skip.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export REPO_ROOT
  export LOG_TAG="test"
  export BRANCH="main"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

  # PATH shims: logger must not hit syslog
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  printf '#!/bin/sh\nexit 0\n' > "$BIN/logger"; chmod +x "$BIN/logger"
  export PATH="$BIN:$PATH"

  ORIGIN="$BATS_TEST_TMPDIR/origin.git"
  DEV="$BATS_TEST_TMPDIR/dev"
  export REPO_DIR="$BATS_TEST_TMPDIR/server"
  git init -q --bare -b main "$ORIGIN"
  git clone -q "$ORIGIN" "$DEV" 2>/dev/null
  (
    cd "$DEV" && git checkout -q -b main
    mkdir -p media configs/data
    echo "v1" > media/docker-compose.yml
    echo '{"a":1}' > configs/data/sonarr.json
    git add . && git commit -qm "initial" && git push -q origin main
  )
  git clone -q "$ORIGIN" "$REPO_DIR" 2>/dev/null
  printf 'DOCKER_DIR=/srv/docker\nMEDIA_DIR=/srv/media\n' > "$REPO_DIR/.env"
}

# Push a commit from the dev clone: dev_commit <subject> <file> <content>
dev_commit() {
  ( cd "$DEV" && mkdir -p "$(dirname "$2")" && echo "$3" > "$2" && git add -A && git commit -qm "$1" && git push -q origin main )
}

# Source lib.sh + 00-pull.sh the way deploy.sh does, then dump the state.
run_pull() {
  run bash -c '
    set -euo pipefail
    cd "$REPO_DIR"
    source "$REPO_ROOT/deploy/lib.sh"
    source "$REPO_ROOT/deploy/00-pull.sh"
    echo "BEFORE=$BEFORE"
    echo "AFTER=$AFTER"
    echo "CHANGED=[$(echo "$CHANGED" | tr "\n" " " | xargs)]"
    echo "DOCKER_DIR=$DOCKER_DIR"
    echo "PW=${PW:-}"
    echo "PW2=${PW2:-}"
  '
}

# --- C1: skip decision is based on the diff, not the tip commit subject ---

@test "C1: an auto-export commit on top of a compose change does NOT skip the deploy" {
  dev_commit "feat(media): bump image" media/docker-compose.yml "v2"
  dev_commit "chore(configs): auto-export 2026-08-20" configs/data/sonarr.json '{"a":2}'
  run_pull
  [ "$status" -eq 0 ]
  [[ "$output" == *"CHANGED=[configs/data/sonarr.json media/docker-compose.yml]"* ]]
  [[ "$output" != *"skipping deploy"* ]]
}

@test "C1: a range touching only configs/data/ skips with exit 0 and records .last-deployed" {
  dev_commit "chore(configs): auto-export" configs/data/sonarr.json '{"a":2}'
  dev_commit "manual config tweak" configs/data/radarr.json '{"b":1}'
  run_pull
  [ "$status" -eq 0 ]
  [[ "$output" == *"Only configs/data/ changed"* ]]
  [[ "$output" != *"CHANGED=["* ]]
  [ "$(cat "$REPO_DIR/.last-deployed")" = "$(git -C "$DEV" rev-parse HEAD)" ]
}

# --- H1: .last-deployed is used as BEFORE when it is an ancestor of HEAD ---

@test "H1: BEFORE resumes from .last-deployed so a previously failed range is re-covered" {
  first=$(git -C "$REPO_DIR" rev-parse HEAD)
  dev_commit "feat(dns): change" dns/docker-compose.yml "d1"
  ( cd "$REPO_DIR" && git pull -q --ff-only origin main )   # pulled, but "failed" → not recorded
  echo "$first" > "$REPO_DIR/.last-deployed"
  dev_commit "feat(media): change" media/docker-compose.yml "v2"
  run_pull
  [ "$status" -eq 0 ]
  [[ "$output" == *"BEFORE=$first"* ]]
  [[ "$output" == *"Resuming from last successful deploy"* ]]
  [[ "$output" == *"CHANGED=[dns/docker-compose.yml media/docker-compose.yml]"* ]]
}

@test "H1: a .last-deployed that is not an ancestor of HEAD is ignored" {
  echo "0123456789abcdef0123456789abcdef01234567" > "$REPO_DIR/.last-deployed"
  head_before=$(git -C "$REPO_DIR" rev-parse HEAD)
  dev_commit "feat(media): change" media/docker-compose.yml "v2"
  run_pull
  [ "$status" -eq 0 ]
  [[ "$output" == *"BEFORE=$head_before"* ]]
}

@test "H1: first run with no .last-deployed behaves as before (HEAD..pulled)" {
  head_before=$(git -C "$REPO_DIR" rev-parse HEAD)
  dev_commit "feat(media): change" media/docker-compose.yml "v2"
  run_pull
  [ "$status" -eq 0 ]
  [[ "$output" == *"BEFORE=$head_before"* ]]
  [[ "$output" == *"CHANGED=[media/docker-compose.yml]"* ]]
}

# --- H4: .env is parsed literally, not sourced ---

@test "H4: .env values with \$, spaces and quotes survive intact and validation still runs" {
  cat > "$REPO_DIR/.env" <<'EOF'
# comment
DOCKER_DIR="/srv/docker"
MEDIA_DIR=/srv/media
PW='p@ss$word with space `nope`'
PW2=p@ss$$word
export EXPORTED=1
not a kv line
EOF
  dev_commit "feat(media): change" media/docker-compose.yml "v2"
  run_pull
  [ "$status" -eq 0 ]
  [[ "$output" == *"DOCKER_DIR=/srv/docker"* ]]
  [[ "$output" == *'PW=p@ss$word with space `nope`'* ]]
  [[ "$output" == *'PW2=p@ss$word'* ]]
}

@test "H4: required-var validation still fails the deploy when DOCKER_DIR is missing" {
  printf 'MEDIA_DIR=/srv/media\n' > "$REPO_DIR/.env"
  run_pull
  [ "$status" -eq 1 ]
  [[ "$output" == *"Required environment variables not set: DOCKER_DIR"* ]]
}

@test "H4: relative path values are still rejected" {
  printf 'DOCKER_DIR=relative/dir\nMEDIA_DIR=/srv/media\n' > "$REPO_DIR/.env"
  run_pull
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be absolute"* ]]
}

# --- H5: network failure is not a dirty tree; stashes get popped ---

@test "H5: fetch failure exits non-zero without stashing untracked files" {
  echo "scratch" > "$REPO_DIR/notes.txt"
  git -C "$REPO_DIR" remote set-url origin "$BATS_TEST_TMPDIR/does-not-exist.git"
  run_pull
  [ "$status" -eq 1 ]
  [[ "$output" == *"git fetch origin/main failed"* ]]
  [ -f "$REPO_DIR/notes.txt" ]
  [ -z "$(git -C "$REPO_DIR" stash list)" ]
}

@test "H5: a genuine collision is stashed and the fast-forward retried" {
  dev_commit "feat(media): change" media/docker-compose.yml "v2"
  echo "local edit" > "$REPO_DIR/media/docker-compose.yml"
  run_pull
  [ "$status" -eq 0 ]
  [[ "$output" == *"Pull blocked by local changes"* ]]
  [ "$(cat "$REPO_DIR/media/docker-compose.yml")" = "v2" ]
  [ -n "$(git -C "$REPO_DIR" stash list)" ]
}

@test "H5: divergence is rebased, not treated as a dirty tree" {
  ( cd "$REPO_DIR" && echo "local" > local.txt && git add local.txt && git commit -qm "local commit" )
  dev_commit "feat(media): change" media/docker-compose.yml "v2"
  run_pull
  [ "$status" -eq 0 ]
  [[ "$output" == *"Rebased onto origin/main"* ]]
  [[ "$output" != *"Pull blocked by local changes"* ]]
  [ -z "$(git -C "$REPO_DIR" stash list)" ]
  [ "$(cat "$REPO_DIR/media/docker-compose.yml")" = "v2" ]
}

@test "H4: .env values match docker compose semantics (inline comments, quotes, \${VAR}, whitespace)" {
  # expected values were produced by `docker compose config` (v5.1.1) on this exact file
  cat > "$REPO_DIR/.env" <<'EOF2'
DOCKER_DIR=/srv/docker
MEDIA_DIR=${DOCKER_DIR}/media
B=with # c
C="quoted" # c
D='single $DOCKER_DIR' # c
F=$DOCKER_DIR-x
G="q ${DOCKER_DIR} #not-comment"
H=hash#inside
I=unset:${ZZZ_UNSET_VAR:-def}
L= spaced 
M="esc\"q"
EOF2
  dev_commit "feat(media): change" media/docker-compose.yml "v2"
  run bash -c '
    set -euo pipefail
    cd "$REPO_DIR"
    source "$REPO_ROOT/deploy/lib.sh"
    source "$REPO_ROOT/deploy/00-pull.sh"
    for v in MEDIA_DIR B C D F G H I L M; do printf "%s=[%s]\n" "$v" "${!v}"; done
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"MEDIA_DIR=[/srv/docker/media]"* ]]
  [[ "$output" == *"B=[with]"* ]]
  [[ "$output" == *"C=[quoted]"* ]]
  [[ "$output" == *'D=[single $DOCKER_DIR]'* ]]
  [[ "$output" == *"F=[/srv/docker-x]"* ]]
  [[ "$output" == *"G=[q /srv/docker #not-comment]"* ]]
  [[ "$output" == *"H=[hash#inside]"* ]]
  [[ "$output" == *"I=[unset:def]"* ]]
  [[ "$output" == *"L=[spaced]"* ]]
  [[ "$output" == *'M=[esc"q]'* ]]
}

@test "H5: diverged + dirty non-conflicting tracked file rebases (autostash) and keeps the local edit" {
  ( cd "$REPO_DIR" && echo "local" > local.txt && git add local.txt && git commit -qm "local commit" )
  echo '{"a":"dirty"}' > "$REPO_DIR/configs/data/sonarr.json"   # tracked, uncommitted, not touched upstream
  dev_commit "feat(media): change" media/docker-compose.yml "v2"
  run_pull
  [ "$status" -eq 0 ]
  [[ "$output" == *"Rebased onto origin/main"* ]]
  [[ "$output" == *"CHANGED=[media/docker-compose.yml]"* ]]
  [ "$(cat "$REPO_DIR/media/docker-compose.yml")" = "v2" ]
  [ "$(cat "$REPO_DIR/configs/data/sonarr.json")" = '{"a":"dirty"}' ]
  [ -z "$(git -C "$REPO_DIR" stash list)" ]
}
