#!/usr/bin/env bash
# secret-guard — block .env secret values from reaching the repo.
#
# Reads KEY=VALUE pairs from .env (gitignored, machine-local) and fails if any
# tracked file about to be committed/pushed contains a literal secret value.
# Matching is on EXACT values from .env, so it catches THIS deployment's real
# keys — complementing gitleaks (which matches generic secret patterns in CI).
#
# A value is guarded when its KEY name matches a secret pattern
# (KEY/SECRET/TOKEN/PASSWORD/PRIVATE/CREDENTIAL) and is long enough. Paths, TZ,
# PUID, etc. are left alone. Tune with SECRET_GUARD_KEY_RE / SECRET_GUARD_MIN_LEN.
#
# The scan reads git BLOBS, never the working tree: `staged` inspects the
# index (`git show :path`), `range` inspects every commit in the range
# (`git show <sha>:path`), so "stage, then edit the secret out" and "add in
# one commit, remove in the next" are both caught. Renames/copies are scanned
# as adds (--no-renames).
#
# Called from .githooks/pre-commit and .githooks/pre-push:
#   secret-guard.sh staged              # scan the staged index (pre-commit)
#   secret-guard.sh range <a> <b>       # scan every commit in a..b (pre-push);
#                                       # a empty or all-zeros → every commit
#                                       # reachable from b but from no remote ref
#   secret-guard.sh --fix               # auto-substitute ${VAR} in shell/compose
#
# Exits 0 clean, 1 if a secret literal is found (--fix exits 1 only if some hit
# could not be auto-fixed). No .env present (CI / fresh clone) → exit 0.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
ENV_FILE="${SECRET_GUARD_ENV:-$ROOT/.env}"
[ -f "$ENV_FILE" ] || exit 0

KEY_RE="${SECRET_GUARD_KEY_RE:-(key|secret|token|pass(word|wd)?|private|credential)}"
MIN_LEN="${SECRET_GUARD_MIN_LEN:-12}"
shopt -s nocasematch   # KEY_RE matches KEY/Key/key alike

# File types where ${VAR} substitution is runtime-correct (bash/compose expand it).
is_fixable() { case "$1" in *.sh|*.bash|docker-compose*.yml|*compose*.yml|*.yml|*.yaml|*.env|*.conf) return 0;; *) return 1;; esac; }

# Drop trusted / non-secret targets: auto-exported config data, env templates, ciphertext.
is_skipped() { case "$1" in configs/data/*|.env*|*.enc.*|*.enc) return 0;; *) return 1;; esac; }

# Build "key<TAB>value" for secret-like keys.
secrets=""
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|\#*) continue;; esac      # blank / comment
  [[ $line == *=* ]] || continue
  key=${line%%=*}
  val=${line#*=}
  # strip a trailing inline comment only when preceded by whitespace (shell conv.)
  case "$val" in *' #'*) val=${val%% #*};; esac
  # strip one pair of surrounding quotes
  case "$val" in \"*\"|\'*\') val=${val:1:${#val}-2};; esac
  val=${val%"${val##*[![:space:]]}"}            # rtrim
  val=${val#"${val%%[![:space:]]*}"}            # ltrim
  [ "${#val}" -ge "$MIN_LEN" ] || continue
  [[ $key =~ $KEY_RE ]] || continue
  secrets+="$key"$'\t'"$val"$'\n'
done < "$ENV_FILE"
[ -n "$secrets" ] || exit 0

# Build the list of blob specs to scan ("<rev>:<path>", as accepted by git show).
# --no-renames: a rename/copy is reported as D + A so the new path is scanned.
DIFF_OPTS=(--no-renames --name-only --diff-filter=ACM)
mode="${1:-staged}"
scan=""
case "$mode" in
  staged|--fix)
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      is_skipped "$f" && continue
      scan+=":$f"$'\n'
    done < <(git diff --cached "${DIFF_OPTS[@]}" || true)
    ;;
  range)
    from="${2:-}"; to="${3:-}"
    [ -n "$to" ] || { echo "secret-guard: range needs <from> <to>" >&2; exit 2; }
    if [ -z "$from" ] || [[ $from =~ ^0+$ ]]; then
      revs=$(git rev-list "$to" --not --remotes 2>/dev/null || true)
    else
      revs=$(git rev-list "$from..$to" 2>/dev/null || true)
    fi
    while IFS= read -r c; do
      [ -n "$c" ] || continue
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        is_skipped "$f" && continue
        scan+="$c:$f"$'\n'
      done < <(git diff-tree --no-commit-id -r --root "${DIFF_OPTS[@]}" "$c" || true)
    done <<< "$revs"
    ;;
  *) echo "secret-guard: unknown mode '$mode' (use: staged | range <a> <b> | --fix)" >&2; exit 2;;
esac
[ -n "$scan" ] || exit 0

# Literal (non-regex) in-place replace of $2 with $3 in worktree file $1.
replace_literal() {
  local file="$1" from="$2" to="$3" content
  IFS= read -r -d '' content < "$file" || true
  printf '%s' "${content//"$from"/"$to"}" > "$file"
}

status=0
while IFS=$'\t' read -r key val; do
  [ -n "$val" ] || continue
  hits=""
  while IFS= read -r spec; do
    [ -n "$spec" ] || continue
    git show "$spec" 2>/dev/null | grep -qIF -- "$val" && hits+="$spec"$'\n'
  done <<< "$scan"
  [ -n "$hits" ] || continue

  if [ "$mode" = "--fix" ]; then
    while IFS= read -r spec; do
      [ -n "$spec" ] || continue
      f="${spec#:}"
      if is_fixable "$f" && [ -f "$ROOT/$f" ]; then
        # Literal value → ${KEY}. Safe in bash/compose (runtime expansion).
        # Only re-stage when the worktree had no other unstaged edits, so
        # unrelated work is never swept into the index.
        if git diff --quiet -- "$f"; then
          replace_literal "$ROOT/$f" "$val" "\${$key}"
          git add -- "$f"
          echo "secret-guard: replaced '$key' value with \${$key} in $f (re-staged)"
        else
          replace_literal "$ROOT/$f" "$val" "\${$key}"
          echo "secret-guard: replaced '$key' value with \${$key} in $f — file has other unstaged changes, review and 'git add $f' yourself" >&2
          status=1
        fi
      else
        echo "secret-guard: ✗ cannot auto-fix $f (not shell/compose) — replace '$key' value manually (e.g. os.environ[\"$key\"] or a deploy-time placeholder)" >&2
        status=1
      fi
    done <<< "$hits"
  else
    echo "secret-guard: literal value of \$${key} found in:" >&2
    while IFS= read -r spec; do
      [ -n "$spec" ] || continue
      case "$spec" in :*) echo "  ${spec#:} (staged)" >&2;; *) echo "  ${spec#*:} @ ${spec%%:*}" >&2;; esac
    done <<< "$hits"
    echo "  → substitute \${$key} (shell/compose), os.environ[\"$key\"] (python), or a deploy-rendered placeholder (JSON); or run: scripts/secret-guard.sh --fix" >&2
    status=1
  fi
done <<< "$secrets"

exit $status
