#!/usr/bin/env bats
# Regression tests for the deploy-pipeline hardening fixes. These pin the
# specific behaviors that were previously broken so they can't silently return.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
}

# --- 10-detect.sh: hot-reload-only commit must not crash under pipefail ---

@test "downgrade filter removing the last stack exits 0 (not a pipefail crash)" {
  run bash -c '
    set -euo pipefail
    STACKS="proxy"; stack="proxy"
    STACKS=$(echo "$STACKS" | tr " " "\n" | { grep -v "^${stack}$" || true; } | tr "\n" " " | xargs)
    echo "STACKS=[$STACKS]"
  '
  [ "$status" -eq 0 ]
  [ "$output" = "STACKS=[]" ]
}

@test "downgrade filter still removes only the named stack" {
  run bash -c '
    set -euo pipefail
    STACKS="proxy monitoring media"; stack="proxy"
    echo "$STACKS" | tr " " "\n" | { grep -v "^${stack}$" || true; } | tr "\n" " " | xargs
  '
  [ "$status" -eq 0 ]
  [ "$output" = "monitoring media" ]
}

@test "10-detect.sh uses the guarded grep, not a bare pipefail-fragile filter" {
  # The fix wraps grep so a no-match can't fail the assignment.
  run grep -F 'grep -v "^${stack}$" || true' "$REPO_ROOT/deploy/10-detect.sh"
  [ "$status" -eq 0 ]
}

# --- 20-deploy.sh: compose up status is checked; gate isn't vacuous ---

@test "20-deploy.sh captures the compose up/build exit via PIPESTATUS" {
  run grep -F 'up_rc=${PIPESTATUS[0]}' "$REPO_ROOT/deploy/20-deploy.sh"
  [ "$status" -eq 0 ]
}

@test "20-deploy.sh fails a non-root stack that produced no containers" {
  run grep -F 'No containers found for $stack after deploy' "$REPO_ROOT/deploy/20-deploy.sh"
  [ "$status" -eq 0 ]
}

# --- 20-deploy.sh: rollback preserves the failure-notification trap ---

@test "rollback captures and restores the prior EXIT trap" {
  run grep -F 'prev_exit_trap=$(trap -p EXIT)' "$REPO_ROOT/deploy/20-deploy.sh"
  [ "$status" -eq 0 ]
  run grep -F 'eval "${prev_exit_trap:-trap - EXIT}"' "$REPO_ROOT/deploy/20-deploy.sh"
  [ "$status" -eq 0 ]
}

@test "trap capture/restore actually re-arms the handler" {
  run bash -c '
    notify() { echo FIRED; }
    trap notify EXIT
    prev=$(trap -p EXIT)
    trap "echo SAFETY; trap - EXIT" EXIT
    eval "${prev:-trap - EXIT}"
  '
  [ "$status" -eq 0 ]
  [ "$output" = "FIRED" ]
}

# --- 20-deploy.sh: a failing rollback does not abort the whole loop ---

@test "rollback is called tolerantly (|| err) so it can't skip remaining stacks" {
  run grep -F 'rollback_stack "$stack" || err' "$REPO_ROOT/deploy/20-deploy.sh"
  [ "$status" -eq 0 ]
}

# --- 30-reload.sh: reload every stack once, and record the applied hash ---

@test "30-reload.sh no longer uses break 2 (which stopped all other reloads)" {
  run grep -F 'break 2' "$REPO_ROOT/deploy/30-reload.sh"
  [ "$status" -ne 0 ]
}

@test "30-reload.sh writes the drift hash after a successful reload" {
  run grep -F 'stack_file_hash "$REPO_DIR/$dir" > "$DEPLOY_HASHES_DIR/$dir"' "$REPO_ROOT/deploy/30-reload.sh"
  [ "$status" -eq 0 ]
}
