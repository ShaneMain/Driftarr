#!/usr/bin/env bats
# Behavioral tests for the smaller pipeline pieces: 90-summary's
# .last-deployed rule, crontab rendering, update.sh core classification, the
# shared deploy/export lock, hot-reload glob handling and drift hashing.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export REPO_ROOT
  export LOG_TAG="test" BUILD_STACKS=""
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  export REPO_DIR="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO_DIR"

  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  printf '#!/bin/sh\nexit 0\n' > "$BIN/logger"
  # fake crontab: -l prints the store, `-` (stdin) replaces it
  cat > "$BIN/crontab" <<'EOF'
#!/bin/bash
STORE="$FAKE_CRONTAB_STORE"
case "$1" in
  -l) [ -f "$STORE" ] && cat "$STORE" || exit 1 ;;
  -)  cat > "$STORE" ;;
  *)  cp "$1" "$STORE" ;;
esac
EOF
  chmod +x "$BIN/logger" "$BIN/crontab"
  export FAKE_CRONTAB_STORE="$BATS_TEST_TMPDIR/crontab.store"
  export PATH="$BIN:$PATH"
}

run_summary() {   # $1=FAILED $2=ROLLED_BACK
  run bash -c '
    set -euo pipefail
    cd "$REPO_DIR"
    source "$REPO_ROOT/deploy/lib.sh"
    BEFORE=aaaaaaaa AFTER=bbbbbbbb FAILED="$1" ROLLED_BACK="$2" SUCCEEDED=" x"
    source "$REPO_ROOT/deploy/90-summary.sh"
  ' _ "$1" "$2"
}

# --- H1: 90-summary only advances .last-deployed on a clean run ---

@test "H1: .last-deployed is written on a clean run" {
  run_summary "" ""
  [ "$status" -eq 0 ]
  [ "$(cat "$REPO_DIR/.last-deployed")" = "bbbbbbbb" ]
}

@test "H1: .last-deployed is NOT written when a stack failed" {
  run_summary " dns" " dns"
  [ "$status" -eq 1 ]
  [ ! -f "$REPO_DIR/.last-deployed" ]
  grep -q 'FAILED$' "$REPO_DIR/.deploy-log"
}

@test "H1: .last-deployed is NOT written when a stack was rolled back (even if FAILED is empty)" {
  run_summary "" " dns"
  [ "$status" -eq 0 ]
  [ ! -f "$REPO_DIR/.last-deployed" ]
}

# --- crontab: $USER/$HOME are rendered at install time ---

@test "40-crontab substitutes \$USER and \$HOME with the deploying user before installing" {
  cat > "$REPO_DIR/crontab" <<'EOF'
# header $USER stays a comment
0 4 * * * /home/$USER/docker-stacks/configs/run-export.sh >> ${HOME}/config-export.log 2>&1
EOF
  run bash -c 'set -euo pipefail; cd "$REPO_DIR"; source "$REPO_ROOT/deploy/lib.sh"; source "$REPO_ROOT/deploy/40-crontab.sh"; echo "CRONTAB_OK=$CRONTAB_OK"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Installing updated crontab"* ]]
  [[ "$output" == *"CRONTAB_OK=true"* ]]
  me=$(id -un)
  grep -qF "/home/$me/docker-stacks/configs/run-export.sh" "$FAKE_CRONTAB_STORE"
  grep -qF "${HOME}/config-export.log" "$FAKE_CRONTAB_STORE"
  ! grep -q '\$USER\|\${HOME}' <(grep -v '^#' "$FAKE_CRONTAB_STORE")
}

@test "40-crontab is idempotent: an already-rendered crontab is not reinstalled" {
  printf '* * * * * /home/$USER/x.sh\n' > "$REPO_DIR/crontab"
  bash -c 'set -euo pipefail; cd "$REPO_DIR"; source "$REPO_ROOT/deploy/lib.sh"; source "$REPO_ROOT/deploy/40-crontab.sh"' >/dev/null
  run bash -c 'set -euo pipefail; cd "$REPO_DIR"; source "$REPO_ROOT/deploy/lib.sh"; source "$REPO_ROOT/deploy/40-crontab.sh"'
  [[ "$output" == *"Crontab unchanged"* ]]
}

# --- H6: update.sh treats deploy/* as core ---

@test "H6: update.sh is_core_file classifies deploy/* modules as core" {
  [ -f "$REPO_ROOT/update.sh" ] || skip "update.sh is template-only (not present in downstream instances)"
  run bash -c '
    set -euo pipefail
    eval "$(sed -n "/^CORE_PATTERNS=(/,/^}/p" "$REPO_ROOT/update.sh")"
    for f in deploy/20-deploy.sh deploy/lib.sh deploy.sh tests/deploy/lib.bats .githooks/pre-commit scripts/secret-guard.sh; do
      is_core_file "$f" && echo "core $f" || echo "user $f"
    done
    for f in media/docker-compose.yml configs/data/sonarr.json .env.example; do
      is_core_file "$f" && echo "core $f" || echo "user $f"
    done
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"core deploy/20-deploy.sh"* ]]
  [[ "$output" == *"core deploy/lib.sh"* ]]
  [[ "$output" == *"core tests/deploy/lib.bats"* ]]
  [[ "$output" == *"core .githooks/pre-commit"* ]]
  [[ "$output" == *"user media/docker-compose.yml"* ]]
  [[ "$output" == *"user configs/data/sonarr.json"* ]]
}

# --- Locking: run-export.sh shares deploy.sh's lock ---

@test "run-export.sh skips with a log line while a deploy holds the lock" {
  printf '#!/bin/sh\necho PYTHON-RAN\n' > "$BIN/python3"; chmod +x "$BIN/python3"
  export DEPLOY_LOCK_FILE="$REPO_DIR/.deploy.lock"
  (
    exec 8>"$DEPLOY_LOCK_FILE"; flock 8
    run_out=$(bash "$REPO_ROOT/configs/run-export.sh")
    echo "$run_out" > "$BATS_TEST_TMPDIR/out"
  )
  run cat "$BATS_TEST_TMPDIR/out"
  [[ "$output" == *"deploy in progress"* ]]
  [[ "$output" != *"PYTHON-RAN"* ]]
}

@test "run-export.sh runs the export when the lock is free" {
  printf '#!/bin/sh\necho PYTHON-RAN\n' > "$BIN/python3"; chmod +x "$BIN/python3"
  export DEPLOY_LOCK_FILE="$REPO_DIR/.deploy.lock"
  run bash "$REPO_ROOT/configs/run-export.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PYTHON-RAN"* ]]
}

@test "deploy.sh and run-export.sh contend for the same default lock file (no DEPLOY_LOCK_FILE set)" {
  printf '#!/bin/sh\necho PYTHON-RAN\n' > "$BIN/python3"; chmod +x "$BIN/python3"
  mkdir -p "$REPO_DIR/deploy"
  unset DEPLOY_LOCK_FILE
  # hold the file deploy.sh defaults to; run-export (REPO_DIR-based default) must see it as taken
  (
    exec 8>"$REPO_DIR/.deploy.lock"; flock 8
    REPO_DIR="$REPO_DIR" bash "$REPO_ROOT/configs/run-export.sh" > "$BATS_TEST_TMPDIR/out1" 2>&1 || true
    rc=0; DEPLOY_REPO_DIR="$REPO_DIR" DEPLOY_LOCK_TIMEOUT=1 bash "$REPO_ROOT/deploy.sh" > "$BATS_TEST_TMPDIR/out2" 2>&1 || rc=$?
    echo "rc=$rc" >> "$BATS_TEST_TMPDIR/out2"
  )
  run cat "$BATS_TEST_TMPDIR/out1"
  [[ "$output" == *"deploy in progress ($REPO_DIR/.deploy.lock held)"* ]]
  [[ "$output" != *"PYTHON-RAN"* ]]
  run cat "$BATS_TEST_TMPDIR/out2"
  [[ "$output" == *"held $REPO_DIR/.deploy.lock"* ]]
  [[ "$output" == *"rc=1"* ]]
}

@test "M8: deploy.sh waits for the lock (bounded) instead of failing immediately" {
  mkdir -p "$REPO_DIR/deploy"
  export DEPLOY_REPO_DIR="$REPO_DIR" DEPLOY_LOCK_TIMEOUT=1
  (
    exec 8>"$REPO_DIR/.deploy.lock"; flock 8
    start=$(date +%s)
    rc=0; bash "$REPO_ROOT/deploy.sh" > "$BATS_TEST_TMPDIR/out" 2>&1 || rc=$?
    echo "rc=$rc" >> "$BATS_TEST_TMPDIR/out"
    echo "elapsed=$(( $(date +%s) - start ))" >> "$BATS_TEST_TMPDIR/out"
  )
  run cat "$BATS_TEST_TMPDIR/out"
  [[ "$output" == *"held"*"for 1s — giving up"* ]]
  [[ "$output" == *"rc=1"* ]]
  ! [[ "$output" == *"elapsed=0"* ]]
}

# --- M1: hot-reload patterns must not glob-expand against the repo root ---

@test "M1: '*.yml' pattern downgrades a prometheus.yml-only commit to hot-reload even with yml files in cwd" {
  mkdir -p "$REPO_DIR/monitoring"
  echo "x" > "$REPO_DIR/common.yml"; echo "x" > "$REPO_DIR/docker-compose.yml"
  echo "x" > "$REPO_DIR/monitoring/docker-compose.yml"
  echo "x" > "$REPO_DIR/monitoring/prometheus.yml"
  printf 'STACK_HOT_RELOAD_PATTERNS="*.yml"\nSTACK_HOT_RELOAD_CMD="true"\n' > "$REPO_DIR/monitoring/stack.conf"
  ( cd "$REPO_DIR" && git init -q -b main && git add -A && git commit -qm init )
  run bash -c '
    set -euo pipefail
    cd "$REPO_DIR"
    source "$REPO_ROOT/deploy/lib.sh"
    CHANGED="monitoring/prometheus.yml"; BEFORE=HEAD; AFTER=HEAD
    mkdir -p .deploy-hashes
    source "$REPO_ROOT/deploy/10-detect.sh"
    echo "STACKS=[$STACKS]"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"STACKS=[]"* ]]
}

@test "M1: 30-reload matches a glob pattern and runs the reload command" {
  mkdir -p "$REPO_DIR/monitoring"
  echo "x" > "$REPO_DIR/common.yml"; echo "x" > "$REPO_DIR/monitoring/docker-compose.yml"
  echo "x" > "$REPO_DIR/monitoring/prometheus.yml"
  printf 'STACK_HOT_RELOAD_PATTERNS="*.yml"\nSTACK_HOT_RELOAD_CMD="echo RELOAD-RAN"\n' > "$REPO_DIR/monitoring/stack.conf"
  ( cd "$REPO_DIR" && git init -q -b main && git add -A && git commit -qm init )
  run bash -c '
    set -euo pipefail
    cd "$REPO_DIR"
    source "$REPO_ROOT/deploy/lib.sh"
    CHANGED="monitoring/prometheus.yml"; PROMETHEUS_RELOAD=false; ALERTMANAGER_RELOAD=false
    DEPLOY_HASHES_DIR="$REPO_DIR/.deploy-hashes"; mkdir -p "$DEPLOY_HASHES_DIR"
    source "$REPO_ROOT/deploy/30-reload.sh"
    echo "CONFIG_RELOADS=[$CONFIG_RELOADS]"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"CONFIG_RELOADS=[ monitoring]"* ]]
  [ -f "$REPO_DIR/.deploy-hashes/monitoring" ]
}

# --- M2: a missing root common.yml must not abort drift detection ---

@test "M2: stack_file_hash succeeds under errexit+pipefail without a root common.yml" {
  mkdir -p "$REPO_DIR/alpha"
  echo "x" > "$REPO_DIR/alpha/docker-compose.yml"; echo "c" > "$REPO_DIR/alpha/app.conf"
  ( cd "$REPO_DIR" && git init -q -b main && git add -A && git commit -qm init )
  run bash -c 'set -euo pipefail; source "$REPO_ROOT/deploy/lib.sh"; h=$(stack_file_hash "$REPO_DIR/alpha"); echo "HASH=$h"'
  [ "$status" -eq 0 ]
  [[ "$output" =~ HASH=[0-9a-f]{32} ]]
}

# --- Item 11: root docker-compose.yml include: list is the stack on/off switch ---

mk_two_stacks() {   # media enabled, monitoring commented out in the root include list
  mkdir -p "$REPO_DIR/media" "$REPO_DIR/monitoring"
  echo "x" > "$REPO_DIR/media/docker-compose.yml"
  echo "x" > "$REPO_DIR/monitoring/docker-compose.yml"
  cat > "$REPO_DIR/docker-compose.yml" <<'YML'
include:
  - media/docker-compose.yml
  # - monitoring/docker-compose.yml
YML
  ( cd "$REPO_DIR" && git init -q -b main && git add -A && git commit -qm init )
  # seed media's drift hash so only genuine changes/drift add it
  mkdir -p "$REPO_DIR/.deploy-hashes"
  bash -c 'source "$REPO_ROOT/deploy/lib.sh"; stack_file_hash "$REPO_DIR/media"' > "$REPO_DIR/.deploy-hashes/media"
}

run_detect() {   # $1 = CHANGED
  run bash -c '
    set -euo pipefail
    cd "$REPO_DIR"
    source "$REPO_ROOT/deploy/lib.sh"
    CHANGED="$1"; BEFORE=HEAD; AFTER=HEAD
    source "$REPO_ROOT/deploy/10-detect.sh"
    echo "STACKS=[$STACKS]"
  ' _ "$1"
}

@test "include: a disabled stack is not deployed on change, not fanned out, and not drift-added" {
  mk_two_stacks
  run_detect "monitoring/docker-compose.yml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipping monitoring — not in root docker-compose.yml include: list"* ]]
  [[ "$output" == *"STACKS=[]"* ]]
  ! grep -q 'Drift detected in monitoring' <<<"$output"

  run_detect $'common.yml\nmonitoring/a.conf\nmonitoring/b.conf'
  [[ "$output" == *"STACKS=[media]"* ]]
  [ "$(grep -c 'Skipping monitoring' <<<"$output")" -eq 1 ]
}

@test "include: uncommenting a stack in the root file enables it (fan-out + drift)" {
  mk_two_stacks
  sed -i 's/# - monitoring/- monitoring/' "$REPO_DIR/docker-compose.yml"
  run_detect "docker-compose.yml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"STACKS=[media monitoring]"* ]]
}

@test "enabled_stacks parses '- path:' (inline and nested) forms and ignores comments" {
  mkdir -p "$REPO_DIR"
  cat > "$REPO_DIR/docker-compose.yml" <<'YML'
name: root
include:
  - path: media/docker-compose.yml
  - path:
      dns/docker-compose.yaml
  - "proxy/docker-compose.yml"   # trailing comment
  # - old/docker-compose.yml
services: {}
YML
  run bash -c 'source "$REPO_ROOT/deploy/lib.sh"; enabled_stacks | tr "\n" " "; stack_enabled dns && echo DNS-ON; stack_enabled old || echo OLD-OFF'
  [ "$status" -eq 0 ]
  [[ "$output" == *"media dns proxy "* ]]
  [[ "$output" == *"DNS-ON"* ]]
  [[ "$output" == *"OLD-OFF"* ]]
}

@test "enabled_stacks falls back to the directory glob when the root file has no include: block" {
  mkdir -p "$REPO_DIR/alpha" "$REPO_DIR/beta" "$REPO_DIR/notastack"
  echo "x" > "$REPO_DIR/alpha/docker-compose.yml"; echo "x" > "$REPO_DIR/beta/docker-compose.yml"
  echo "services: {}" > "$REPO_DIR/docker-compose.yml"
  run bash -c 'source "$REPO_ROOT/deploy/lib.sh"; enabled_stacks | tr "\n" " "'
  [ "$output" = "alpha beta " ]
  rm "$REPO_DIR/docker-compose.yml"
  run bash -c 'source "$REPO_ROOT/deploy/lib.sh"; enabled_stacks | tr "\n" " "'
  [ "$output" = "alpha beta " ]
}

@test "enabled_stacks accepts ./-prefixed, path:-prefixed, quoted and nested entries" {
  cat > "$REPO_DIR/docker-compose.yml" <<'YML'
include:
  - ./media/docker-compose.yml
  - path: ./dns/docker-compose.yml
  - "proxy/docker-compose.yml"
  - 'stacks/deep/docker-compose.yaml'
services: {}
YML
  run bash -c 'source "$REPO_ROOT/deploy/lib.sh"; enabled_stacks | tr "\n" " "'
  [ "$status" -eq 0 ]
  [ "$output" = "media dns proxy stacks/deep " ]
}

@test "enabled_stacks accepts a flow-style include list" {
  printf 'include: [media/docker-compose.yml, "./dns/docker-compose.yml"]\nservices: {}\n' > "$REPO_DIR/docker-compose.yml"
  run bash -c 'source "$REPO_ROOT/deploy/lib.sh"; enabled_stacks | tr "\n" " "'
  [ "$output" = "media dns " ]
}

@test "enabled_stacks warns and falls back to the glob when the include block yields no stacks" {
  mkdir -p "$REPO_DIR/alpha"; echo "x" > "$REPO_DIR/alpha/docker-compose.yml"
  printf 'include:\n  - project_directory: weird\n' > "$REPO_DIR/docker-compose.yml"
  run bash -c 'source "$REPO_ROOT/deploy/lib.sh"; enabled_stacks'
  [ "$status" -eq 0 ]
  [[ "$output" == *"no parsable stack entries"* ]]
  [[ "$output" == *"alpha"* ]]
}

@test "include: a ./-prefixed entry is deployed (not logged as disabled)" {
  mk_two_stacks
  printf 'include:\n  - ./media/docker-compose.yml\n' > "$REPO_DIR/docker-compose.yml"
  run_detect "media/docker-compose.yml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"STACKS=[media]"* ]]
  [[ "$output" != *"Skipping media"* ]]
}

@test "40-crontab substitutes only whole \$USER/\$HOME tokens (\$HOMEDIR, \$USERNAME untouched)" {
  printf '* * * * * $HOMEDIR/a $USERNAME $USER$HOME ${HOME}/b $HOME\n' > "$REPO_DIR/crontab"
  run bash -c 'set -euo pipefail; cd "$REPO_DIR"; source "$REPO_ROOT/deploy/lib.sh"; source "$REPO_ROOT/deploy/40-crontab.sh"'
  [ "$status" -eq 0 ]
  me=$(id -un)
  [ "$(grep -v '^$' "$FAKE_CRONTAB_STORE")" = "* * * * * \$HOMEDIR/a \$USERNAME $me$HOME $HOME/b $HOME" ]
}
