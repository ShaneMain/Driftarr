#!/usr/bin/env bats
# Tests for scripts/secret-guard.sh and .githooks/pre-push against a scratch repo.
# Run: bats tests/guard/

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  GUARD="$REPO_ROOT/scripts/secret-guard.sh"
  PRE_PUSH="$REPO_ROOT/.githooks/pre-push"
  SECRET='AAAAAAAAAAAAAAAAAAAA1111'
  PIPE_SECRET='abc|def*ghi.jkl[mn]&x/y'

  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
  git config --global init.defaultBranch main

  # "remote" bare repo + working clone. The hooks resolve scripts/ relative to
  # the repo they run in, so copy the guard into the scratch repo as well.
  git init -q --bare "$BATS_TEST_TMPDIR/remote.git"
  git init -q "$BATS_TEST_TMPDIR/work"
  cd "$BATS_TEST_TMPDIR/work"
  mkdir -p scripts && cp "$GUARD" scripts/secret-guard.sh
  git remote add origin "$BATS_TEST_TMPDIR/remote.git"
  printf 'API_KEY=%s\nPIPE_PASSWORD="%s"\nTZ=Europe/London\n' "$SECRET" "$PIPE_SECRET" > .env
  printf '.env\n' > .gitignore
  echo base > base.txt
  git add .gitignore base.txt scripts/secret-guard.sh
  git commit -qm base
  git push -q origin main
}

# ── staged mode ────────────────────────────────────────────────────────────

@test "staged: blocks a secret in a staged file" {
  printf 'k = "%s"\n' "$SECRET" > a.py
  git add a.py
  run "$GUARD" staged
  [ "$status" -eq 1 ]
  [[ "$output" == *"API_KEY"* && "$output" == *"a.py"* ]]
}

@test "staged: scans the index, not the worktree (secret staged then edited out)" {
  printf 'k = "%s"\n' "$SECRET" > sneak.py
  git add sneak.py
  echo 'k = os.environ["API_KEY"]' > sneak.py   # worktree clean, index dirty
  run "$GUARD" staged
  [ "$status" -eq 1 ]
  [[ "$output" == *"sneak.py"* ]]
}

@test "staged: secret only in the unstaged worktree copy does not block" {
  echo 'k = 1' > ok.py
  git add ok.py
  printf 'k = "%s"\n' "$SECRET" > ok.py   # not staged
  run "$GUARD" staged
  [ "$status" -eq 0 ]
}

@test "staged: renamed file with an appended secret is scanned" {
  echo 'k = 1' > old.py
  git add old.py && git commit -qm old
  git mv old.py new.py
  printf 'k = "%s"\n' "$SECRET" >> new.py
  git add new.py
  run "$GUARD" staged
  [ "$status" -eq 1 ]
  [[ "$output" == *"new.py"* ]]
}

@test "staged: clean index passes" {
  echo clean > c.txt
  git add c.txt
  run "$GUARD" staged
  [ "$status" -eq 0 ]
}

# ── --fix mode ─────────────────────────────────────────────────────────────

@test "--fix: replaces a secret containing sed metacharacters literally" {
  printf 'PW="%s"\nUNRELATED="abcXdefXghi.jklXmnX&x/y"\n' "$PIPE_SECRET" > run.sh
  git add run.sh
  run "$GUARD" --fix
  [ "$status" -eq 0 ]
  grep -qF 'PW="${PIPE_PASSWORD}"' run.sh
  grep -qF 'UNRELATED="abcXdefXghi.jklXmnX&x/y"' run.sh
  # re-staged: index now clean
  run "$GUARD" staged
  [ "$status" -eq 0 ]
}

@test "--fix: does not sweep unrelated unstaged edits into the index" {
  printf 'KEY="%s"\n' "$SECRET" > s.sh
  git add s.sh
  echo 'echo unrelated' >> s.sh   # unstaged extra work
  run "$GUARD" --fix
  [ "$status" -eq 1 ]
  grep -qF 'KEY="${API_KEY}"' s.sh
  ! git show :s.sh | grep -qF 'unrelated'
}

# ── range mode / pre-push ──────────────────────────────────────────────────

@test "range: secret added and removed inside one push is still caught" {
  printf 'k = "%s"\n' "$SECRET" > leak.py
  git add leak.py && git commit -qm add
  echo 'k = 1' > leak.py
  git add leak.py && git commit -qm remove
  run "$GUARD" range "$(git rev-parse origin/main)" "$(git rev-parse HEAD)"
  [ "$status" -eq 1 ]
  [[ "$output" == *"leak.py"* ]]
}

@test "pre-push: fast-forward push with a clean range passes" {
  echo ok > ok.txt
  git add ok.txt && git commit -qm ok
  run bash -c "printf 'refs/heads/main %s refs/heads/main %s\n' '$(git rev-parse HEAD)' '$(git rev-parse origin/main)' | '$PRE_PUSH'"
  [ "$status" -eq 0 ]
}

@test "pre-push: brand-new branch is scanned, not skipped" {
  git checkout -qb feature
  printf 'k = "%s"\n' "$SECRET" > feat.py
  git add feat.py && git commit -qm feat
  ZERO=0000000000000000000000000000000000000000
  run bash -c "printf 'refs/heads/feature %s refs/heads/feature %s\n' '$(git rev-parse HEAD)' '$ZERO' | '$PRE_PUSH'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"feat.py"* ]]
}

@test "pre-push: new branch only scans commits not already on a remote" {
  git checkout -qb feature2
  echo ok > ok2.txt
  git add ok2.txt && git commit -qm ok2
  ZERO=0000000000000000000000000000000000000000
  run bash -c "printf 'refs/heads/feature2 %s refs/heads/feature2 %s\n' '$(git rev-parse HEAD)' '$ZERO' | '$PRE_PUSH'"
  [ "$status" -eq 0 ]
}

@test "env parsing: quoted value with trailing comment is unquoted and matched" {
  printf 'QUOTED_TOKEN="quoted-secret-value-1" # comment\n' > .env
  printf 'x = "quoted-secret-value-1"\n' > q.py
  git add q.py
  run "$GUARD" staged
  [ "$status" -eq 1 ]
  [[ "$output" == *"QUOTED_TOKEN"* ]]
}

@test "no .env → exit 0" {
  rm .env
  printf 'k = "%s"\n' "$SECRET" > a.py
  git add a.py
  run "$GUARD" staged
  [ "$status" -eq 0 ]
}
