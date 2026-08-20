#!/usr/bin/env bats
# Behavioral tests for deploy_stack's health/exit gates (20-deploy.sh) and
# the config-sync module (50-config-sync.sh), driven by a fake `docker` shim.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export REPO_ROOT
  export LOG_TAG="test" BUILD_STACKS="" CONFIG_SYNC_STACK="media"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

  export REPO_DIR="$BATS_TEST_TMPDIR/repo"
  export DEPLOY_HASHES_DIR="$REPO_DIR/.deploy-hashes"
  mkdir -p "$REPO_DIR/media" "$REPO_DIR/configs/data" "$DEPLOY_HASHES_DIR"
  echo "services: {}" > "$REPO_DIR/media/docker-compose.yml"
  echo '{"rev":"BEFORE"}' > "$REPO_DIR/configs/data/sonarr.json"
  ( cd "$REPO_DIR" && git init -q -b main && git add -A && git commit -qm before )
  export BEFORE; BEFORE=$(git -C "$REPO_DIR" rev-parse HEAD)
  echo '{"rev":"AFTER"}' > "$REPO_DIR/configs/data/sonarr.json"
  ( cd "$REPO_DIR" && git add -A && git commit -qm after )
  export AFTER; AFTER=$(git -C "$REPO_DIR" rev-parse HEAD)

  # ── fake docker ──
  export FAKE_PS="$BATS_TEST_TMPDIR/ps.tsv"      # name<TAB>state<TAB>health<TAB>exitcode
  export FAKE_LOG="$BATS_TEST_TMPDIR/docker.log"
  export FAKE_UP_RC=0 FAKE_WAIT_RC=0 FAKE_WAIT_HOOK=""
  : > "$FAKE_PS"; : > "$FAKE_LOG"
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  printf '#!/bin/sh\nexit 0\n' > "$BIN/logger"
  cat > "$BIN/docker" <<'EOF'
#!/bin/bash
echo "$*" >> "$FAKE_LOG"
case " $* " in
  *" --status=created "*) exit 0 ;;
  *" ps "*"--format"*)     cat "$FAKE_PS" ;;
  *" up "*)                exit "$FAKE_UP_RC" ;;
  *" wait "*)              [ -n "$FAKE_WAIT_HOOK" ] && eval "$FAKE_WAIT_HOOK"; echo "$FAKE_WAIT_RC" ;;
  *" logs "*)              echo "fake log line" ;;
  *)                       exit 0 ;;
esac
EOF
  chmod +x "$BIN/logger" "$BIN/docker"
  export PATH="$BIN:$PATH"
}

ps_table() { printf '%b\n' "$@" > "$FAKE_PS"; }

# Source lib + 20-deploy with an empty STACKS (loop is a no-op), then call
# deploy_stack directly. `sleep` is overridden so the settle loops are instant.
run_deploy_stack() {
  run bash -c '
    set -euo pipefail
    cd "$REPO_DIR"
    source "$REPO_ROOT/deploy/lib.sh"
    sleep() { :; }
    STACKS=""
    source "$REPO_ROOT/deploy/20-deploy.sh"
    if deploy_stack media; then echo "RESULT=ok"; else echo "RESULT=fail"; fi
  '
}

# --- H3: gates test the state/health columns, not the "name status" line ---

@test "H3: a restarting container named uptime-kuma fails the gate (name contains 'up')" {
  ps_table 'uptime-kuma\trestarting\t\t1' 'backup\texited\t\t1'
  run_deploy_stack
  [ "$status" -eq 0 ]
  [[ "$output" == *"Non-running containers detected"* ]]
  [[ "$output" == *"uptime-kuma (restarting)"* ]]
  [[ "$output" == *"RESULT=fail"* ]]
}

@test "H3: an unhealthy container is caught via the health column" {
  ps_table 'sonarr\trunning\tunhealthy\t0'
  run_deploy_stack
  [[ "$output" == *"Unhealthy containers detected"* ]]
  [[ "$output" == *"RESULT=fail"* ]]
}

@test "H3: a container NAMED unhealthy-checker that is healthy passes" {
  ps_table 'unhealthy-checker\trunning\thealthy\t0' 'radarr\trunning\t\t0'
  run_deploy_stack
  [[ "$output" == *"RESULT=ok"* ]]
  [[ "$output" != *"Unhealthy containers"* ]]
}

@test "H3: a cleanly exited one-shot passes; a failed one-shot is reported with its exit code" {
  ps_table 'config-sync\texited\t\t0' 'sonarr\trunning\thealthy\t0'
  run_deploy_stack
  [[ "$output" == *"RESULT=ok"* ]]

  ps_table 'db-migrate\texited\t\t3' 'sonarr\trunning\thealthy\t0'
  run_deploy_stack
  [[ "$output" == *"RESULT=fail"* ]]
  [[ "$output" == *"db-migrate (exited)"* ]]
}

@test "H3: a running service named syncthing is not treated as a one-shot to wait for" {
  ps_table 'syncthing\trunning\thealthy\t0'
  run_deploy_stack
  [[ "$output" == *"RESULT=ok"* ]]
  [[ "$output" != *"Waiting for one-shot containers"* ]]
}

@test "H3: is_oneshot_name matches whole name components only" {
  source "$REPO_ROOT/deploy/lib.sh"
  is_oneshot_name config-sync
  is_oneshot_name db_migrate
  is_oneshot_name oneshot
  ! is_oneshot_name syncthing
  ! is_oneshot_name rsync-server
  ! is_oneshot_name migrated-app
}

@test "deploy_stack still fails when compose up itself fails" {
  export FAKE_UP_RC=1
  ps_table 'sonarr\trunning\thealthy\t0'
  run_deploy_stack
  [[ "$output" == *"compose build/up failed"* ]]
  [[ "$output" == *"RESULT=fail"* ]]
}

# --- H2 / M5: 50-config-sync.sh ---

run_config_sync() {   # $1 = ROLLED_BACK value
  run bash -c '
    set -euo pipefail
    cd "$REPO_DIR"
    source "$REPO_ROOT/deploy/lib.sh"
    ROLLED_BACK="$1"; CHANGED=""; FAILED=""
    source "$REPO_ROOT/deploy/50-config-sync.sh"
    echo "POST FAILED=[$FAILED] CONFIG_SYNC_OK=$CONFIG_SYNC_OK"
  ' _ "$1"
}

@test "H2: a rollback of an unrelated stack does NOT revert configs/data to BEFORE" {
  export FAKE_WAIT_HOOK='cp "$REPO_DIR/configs/data/sonarr.json" "$BATS_TEST_TMPDIR/seen.json"'
  run_config_sync " dns"
  [ "$status" -eq 0 ]
  [[ "$output" != *"using config data from"* ]]
  [ "$(cat "$BATS_TEST_TMPDIR/seen.json")" = '{"rev":"AFTER"}' ]
  [[ "$output" == *"CONFIG_SYNC_OK=true"* ]]
}

@test "H2: a rollback of the config-sync stack itself applies BEFORE's data, then restores AFTER" {
  export FAKE_WAIT_HOOK='cp "$REPO_DIR/configs/data/sonarr.json" "$BATS_TEST_TMPDIR/seen.json"'
  run_config_sync " dns media"
  [ "$status" -eq 0 ]
  [[ "$output" == *"media was rolled back — using config data from"* ]]
  [ "$(cat "$BATS_TEST_TMPDIR/seen.json")" = '{"rev":"BEFORE"}' ]
  [ "$(cat "$REPO_DIR/configs/data/sonarr.json")" = '{"rev":"AFTER"}' ]
}

@test "H2: the '(stopped)' rollback marker of the config-sync stack also triggers the revert" {
  export FAKE_WAIT_HOOK='cp "$REPO_DIR/configs/data/sonarr.json" "$BATS_TEST_TMPDIR/seen.json"'
  run_config_sync " media(stopped)"
  [ "$(cat "$BATS_TEST_TMPDIR/seen.json")" = '{"rev":"BEFORE"}' ]
}

@test "M5: a failing 'compose up config-sync' is recorded in FAILED instead of aborting the module" {
  export FAKE_UP_RC=1
  run_config_sync ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not start config-sync"* ]]
  [[ "$output" == *"POST FAILED=[ config-sync] CONFIG_SYNC_OK=false"* ]]
  ! grep -q ' wait ' "$FAKE_LOG"
}

@test "config-sync non-zero exit is still a failure with logs shown" {
  export FAKE_WAIT_RC=2
  run_config_sync ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"exited with code 2"* ]]
  [[ "$output" == *"fake log line"* ]]
  [[ "$output" == *"FAILED=[ config-sync]"* ]]
}
