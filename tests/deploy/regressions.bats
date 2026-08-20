#!/usr/bin/env bats
# Regression tests for the deploy-pipeline hardening fixes. These pin the
# specific behaviors that were previously broken so they can't silently
# return — by exercising the modules against a scratch repo and a fake
# `docker`, not by grepping the source.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export REPO_ROOT
  export LOG_TAG="test" BUILD_STACKS=""
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  export REPO_DIR="$BATS_TEST_TMPDIR/repo"
  export DEPLOY_HASHES_DIR="$REPO_DIR/.deploy-hashes"
  mkdir -p "$REPO_DIR/alpha" "$REPO_DIR/beta" "$DEPLOY_HASHES_DIR"
  echo "x" > "$REPO_DIR/alpha/docker-compose.yml"
  echo "x" > "$REPO_DIR/beta/docker-compose.yml"
  echo "c" > "$REPO_DIR/alpha/app.conf"; echo "c" > "$REPO_DIR/beta/app.conf"
  printf 'STACK_HOT_RELOAD_PATTERNS="*.conf"\nSTACK_HOT_RELOAD_CMD="echo RELOAD-%s"\n' alpha > "$REPO_DIR/alpha/stack.conf"
  printf 'STACK_HOT_RELOAD_PATTERNS="*.conf"\nSTACK_HOT_RELOAD_CMD="echo RELOAD-%s"\n' beta > "$REPO_DIR/beta/stack.conf"
  ( cd "$REPO_DIR" && git init -q -b main && git add -A && git commit -qm init )
  export BEFORE AFTER; BEFORE=$(git -C "$REPO_DIR" rev-parse HEAD); AFTER=$BEFORE
  for s in alpha beta; do
    bash -c 'source "$REPO_ROOT/deploy/lib.sh"; stack_file_hash "$REPO_DIR/'"$s"'"' > "$DEPLOY_HASHES_DIR/$s"
  done

  export FAKE_PS="$BATS_TEST_TMPDIR/ps.tsv" FAKE_LOG="$BATS_TEST_TMPDIR/docker.log" FAKE_UP_RC=0
  : > "$FAKE_PS"; : > "$FAKE_LOG"
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  printf '#!/bin/sh\nexit 0\n' > "$BIN/logger"
  cat > "$BIN/docker" <<'EOF'
#!/bin/bash
echo "$*" >> "$FAKE_LOG"
case " $* " in
  *" --status=created "*) exit 0 ;;
  *" ps "*"--format"*)     [ -n "${FAKE_PS_FOR:-}" ] && [[ " $* " == *" -p $FAKE_PS_FOR "* ]] && exit 0; cat "$FAKE_PS" ;;
  *" up "*)                [ -n "${FAKE_UP_FAIL_FOR:-}" ] && [[ " $* " == *" -p $FAKE_UP_FAIL_FOR "* ]] && exit 1; exit "$FAKE_UP_RC" ;;
  *)                       exit 0 ;;
esac
EOF
  chmod +x "$BIN/logger" "$BIN/docker"
  export PATH="$BIN:$PATH"
}

run_module() {   # run_module <module> <preset-shell>
  run bash -c '
    set -euo pipefail
    cd "$REPO_DIR"
    source "$REPO_ROOT/deploy/lib.sh"
    sleep() { :; }
    eval "$2"
    source "$REPO_ROOT/deploy/$1.sh"
    echo "POST STACKS=[${STACKS:-}] SUCCEEDED=[${SUCCEEDED:-}] FAILED=[${FAILED:-}] ROLLED_BACK=[${ROLLED_BACK:-}] CONFIG_RELOADS=[${CONFIG_RELOADS:-}]"
  ' _ "$1" "$2"
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

@test "10-detect: a commit touching only one stack's hot-reloadable file leaves STACKS empty and exits 0" {
  run_module 10-detect 'CHANGED="alpha/app.conf"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"POST STACKS=[]"* ]]
}

# --- 20-deploy.sh: compose up status is checked; gate isn't vacuous ---

@test "20-deploy: a failed compose up is a deploy failure even if old containers still look healthy" {
  printf 'alpha-app\trunning\thealthy\t0\n' > "$FAKE_PS"
  export FAKE_UP_RC=1
  run_module 20-deploy 'STACKS="alpha"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"compose build/up failed for alpha"* ]]
  [[ "$output" == *"FAILED=[ alpha]"* ]]
}

@test "20-deploy: a stack that produced no containers fails instead of passing vacuously" {
  : > "$FAKE_PS"
  run_module 20-deploy 'STACKS="alpha"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"No containers found for alpha after deploy"* ]]
  [[ "$output" == *"FAILED=[ alpha]"* ]]
  [[ "$output" == *"SUCCEEDED=[]"* ]]
}

# --- 20-deploy.sh: rollback preserves the failure-notification trap ---

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

@test "20-deploy: the EXIT handler installed before a rollback still fires afterwards" {
  export FAKE_UP_FAIL_FOR=alpha
  printf 'beta-app\trunning\thealthy\t0\n' > "$FAKE_PS"
  run_module 20-deploy 'trap "echo NOTIFIER-FIRED" EXIT; STACKS="alpha"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"ROLLED_BACK=[ alpha]"* ]]
  [[ "$output" == *"NOTIFIER-FIRED"* ]]
}

# --- 20-deploy.sh: a failing deploy + rollback does not abort the loop ---

@test "20-deploy: remaining stacks still deploy after an earlier stack fails and is rolled back" {
  export FAKE_UP_FAIL_FOR=alpha
  printf 'beta-app\trunning\thealthy\t0\n' > "$FAKE_PS"
  run_module 20-deploy 'STACKS="alpha beta"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"FAILED=[ alpha]"* ]]
  [[ "$output" == *"ROLLED_BACK=[ alpha]"* ]]
  [[ "$output" == *"SUCCEEDED=[ beta]"* ]]
  grep -q -- '-p beta .* up -d' "$FAKE_LOG"
}

# --- 30-reload.sh: reload every stack once, and record the applied hash ---

@test "30-reload: changes in two stacks reload BOTH stacks, each exactly once" {
  rm "$DEPLOY_HASHES_DIR/alpha" "$DEPLOY_HASHES_DIR/beta"
  run_module 30-reload 'CHANGED=$'"'"'alpha/app.conf\nalpha/other.conf\nbeta/app.conf'"'"'; PROMETHEUS_RELOAD=false; ALERTMANAGER_RELOAD=false'
  [ "$status" -eq 0 ]
  [[ "$output" == *"CONFIG_RELOADS=[ alpha beta]"* ]]
  [ "$(grep -c 'RELOAD-alpha' <<<"$output")" -eq 1 ]
  [ "$(grep -c 'RELOAD-beta' <<<"$output")" -eq 1 ]
}

@test "30-reload: a successful reload writes the stack's drift hash so the next run doesn't redeploy it" {
  rm "$DEPLOY_HASHES_DIR/alpha"
  run_module 30-reload 'CHANGED="alpha/app.conf"; PROMETHEUS_RELOAD=false; ALERTMANAGER_RELOAD=false'
  [ "$status" -eq 0 ]
  [ -f "$DEPLOY_HASHES_DIR/alpha" ]
  expected=$(bash -c 'source "$REPO_ROOT/deploy/lib.sh"; stack_file_hash "$REPO_DIR/alpha"')
  [ "$(cat "$DEPLOY_HASHES_DIR/alpha")" = "$expected" ]
  # and 10-detect now sees no drift for alpha
  run_module 10-detect 'CHANGED=""'
  ! grep -q 'Drift detected in alpha' <<<"$output"
}
