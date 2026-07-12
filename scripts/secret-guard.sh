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
# Called from .githooks/pre-commit and .githooks/pre-push:
#   secret-guard.sh staged              # scan the staged diff (pre-commit)
#   secret-guard.sh range <a> <b>       # scan commits in range a..b (pre-push)
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

# Build "key<TAB>value" for secret-like keys.
secrets=""
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|\#*) continue;; esac      # blank / comment
  [[ $line == *=* ]] || continue
  key=${line%%=*}
  val=${line#*=}
  # strip a trailing inline comment only when preceded by whitespace (shell conv.)
  case "$val" in *' '#'*) val=${val%% *#*};; esac
  # strip one pair of surrounding quotes
  case "$val" in \"*\"|\'*\') val=${val:1:${#val}-2};; esac
  val=${val%"${val##*[![:space:]]}"}            # rtrim
  val=${val#"${val%%[![:space:]]*}"}            # ltrim
  [ "${#val}" -ge "$MIN_LEN" ] || continue
  [[ $key =~ $KEY_RE ]] || continue
  secrets+="$key"$'\t'"$val"$'\n'
done < "$ENV_FILE"
[ -n "$secrets" ] || exit 0

mode="${1:-staged}"
case "$mode" in
  staged|--fix) files=$(git diff --cached --name-only --diff-filter=ACM || true);;
  range)        files=$(git diff --name-only --diff-filter=ACM "$2" "$3" || true);;
  *) echo "secret-guard: unknown mode '$mode' (use: staged | range <a> <b> | --fix)" >&2; exit 2;;
esac
[ -n "$files" ] || exit 0

# Drop trusted / non-secret targets: auto-exported config data, env templates, ciphertext.
scan=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in configs/data/*|.env*|*.enc.*|*.enc) continue;; esac
  scan+="$f"$'\n'
done <<< "$files"
[ -n "$scan" ] || exit 0

status=0
while IFS=$'\t' read -r key val; do
  [ -n "$val" ] || continue
  hits=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    grep -qIF -- "$val" "$f" 2>/dev/null && hits+="$f"$'\n'
  done <<< "$scan"
  [ -n "$hits" ] || continue

  if [ "$mode" = "--fix" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if is_fixable "$f"; then
        # Literal value → ${KEY}. Safe in bash/compose (runtime expansion).
        printf -v repl '%s' "${key}"
        sed -i "s|${val}|\${${repl}}|g" "$f"
        git add "$f"
        echo "secret-guard: replaced '$key' value with \${$key} in $f"
      else
        echo "secret-guard: ✗ cannot auto-fix $f (not shell/compose) — replace '$key' value manually (e.g. os.environ[\"$key\"] or a deploy-time placeholder)" >&2
        status=1
      fi
    done <<< "$hits"
  else
    echo "secret-guard: literal value of \$${key} found in:" >&2
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      echo "  $f" >&2
    done <<< "$hits"
    echo "  → substitute \${$key} (shell/compose), os.environ[\"$key\"] (python), or a deploy-rendered placeholder (JSON); or run: scripts/secret-guard.sh --fix" >&2
    status=1
  fi
done <<< "$secrets"

exit $status
