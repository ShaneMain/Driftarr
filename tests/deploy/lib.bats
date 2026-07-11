#!/usr/bin/env bats
# Unit tests for deploy/lib.sh helper functions.
# Run: bats tests/deploy/

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export LOG_TAG="test"
  export REPO_DIR="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO_DIR/alpha" "$REPO_DIR/beta"
  cat > "$REPO_DIR/alpha/stack.conf" <<'EOF'
STACK_BUILD_REQUIRED=yes
STACK_HEALTH_TIMEOUT=180
STACK_HOT_RELOAD_PATTERNS="*.conf config/*"
STACK_HOT_RELOAD_CMD="echo reload"
EOF
  BUILD_STACKS=""
  # shellcheck disable=SC1091
  source "$REPO_ROOT/deploy/lib.sh"
}

@test "stack_conf reads a configured value" {
  run stack_conf alpha STACK_HEALTH_TIMEOUT 90
  [ "$status" -eq 0 ]
  [ "$output" = "180" ]
}

@test "stack_conf falls back to default for a missing key" {
  run stack_conf alpha STACK_NOT_PRESENT fallback
  [ "$output" = "fallback" ]
}

@test "stack_conf falls back to default when stack.conf is absent" {
  run stack_conf beta STACK_HEALTH_TIMEOUT 90
  [ "$output" = "90" ]
}

@test "stack_conf strips surrounding double quotes" {
  run stack_hot_reload_cmd alpha
  [ "$output" = "echo reload" ]
}

@test "stack_hot_reload_patterns returns the space-separated globs" {
  run stack_hot_reload_patterns alpha
  [ "$output" = "*.conf config/*" ]
}

@test "needs_build is true when STACK_BUILD_REQUIRED=yes" {
  run needs_build alpha
  [ "$status" -eq 0 ]
}

@test "needs_build is false with no stack.conf and empty BUILD_STACKS" {
  run needs_build beta
  [ "$status" -ne 0 ]
}

@test "needs_build honors the global BUILD_STACKS fallback" {
  BUILD_STACKS="beta"
  run needs_build beta
  [ "$status" -eq 0 ]
}

@test "stack_health_timeout defaults to 90 without a stack.conf" {
  run stack_health_timeout beta
  [ "$output" = "90" ]
}

@test "compose_cmd for a stack targets its project and compose file" {
  # Stub docker to echo its args instead of running.
  docker() { echo "docker $*"; }
  export -f docker
  run compose_cmd alpha ps
  [ "$status" -eq 0 ]
  [ "$output" = "docker compose -p alpha -f $REPO_DIR/alpha/docker-compose.yml ps" ]
}
