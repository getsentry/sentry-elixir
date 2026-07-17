#!/usr/bin/env bash

set -euo pipefail

bucket="${1:?Usage: $0 <bucket> (one of: 1.13-1.14, 1.15-1.17, 1.18, default)}"

if [ "$bucket" = "default" ]; then
  suffix="mix.lock"
else
  suffix="mix-${bucket}.lock"
fi

mapfile -t lockfiles < <(git ls-files -- "$suffix" "test_integrations/*/$suffix")

if [ "${#lockfiles[@]}" -eq 0 ]; then
  echo "No lockfiles found for bucket '$bucket' (suffix: $suffix)" >&2
  exit 1
fi

echo "==> Elixir/OTP in use: $(elixir --version | tr '\n' ' ')"
echo "==> Lockfiles to refresh: ${lockfiles[*]}"

list_update_candidates() {
  local out
  out=$(mix hex.outdated 2>/dev/null) || true
  # `|| true`: with `pipefail`, grep matching zero rows (nothing outdated) would
  # otherwise make this function - and the `set -e` script calling it - exit 1.
  printf '%s\n' "$out" | grep -E 'Update possible[[:space:]]*$' | awk '{print $1, $(NF-2)}' || true
}

summary_target="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
output_target="${GITHUB_OUTPUT:-/dev/null}"

for lock in "${lockfiles[@]}"; do
  dir=$(dirname "$lock")
  echo "==> Refreshing $lock in $dir"

  candidates=$(cd "$dir" && list_update_candidates)
  summary_rows=()

  if (cd "$dir" && mix deps.update --all && MIX_ENV=test mix compile); then
    echo "==> Bulk update succeeded for $lock"
    while IFS=' ' read -r dep latest; do
      [ -z "$dep" ] && continue
      summary_rows+=("| $dep | $latest | bumped (bulk) |")
    done <<< "$candidates"
  else
    echo "==> Bulk update (or its compile check) failed for $lock, falling back to per-dependency updates"
    git checkout -- "$lock"
    (cd "$dir" && mix deps.get)

    good_lock=$(cat "$lock")

    while IFS=' ' read -r dep latest; do
      [ -z "$dep" ] && continue
      echo "----> Trying $dep -> $latest"
      if (cd "$dir" && mix deps.update "$dep" && MIX_ENV=test mix compile); then
        good_lock=$(cat "$lock")
        summary_rows+=("| $dep | $latest | bumped (individually) |")
      else
        printf '%s\n' "$good_lock" > "$lock"
        (cd "$dir" && mix deps.get)
        echo "::warning::[$lock] Skipped $dep -> $latest: breaks MIX_ENV=test mix compile on bucket $bucket"
        summary_rows+=("| $dep | $latest | skipped (breaks compile) |")
      fi
    done <<< "$candidates"
  fi

  if [ "${#summary_rows[@]}" -gt 0 ]; then
    {
      echo "### $lock"
      echo ""
      echo "| Dependency | Latest | Result |"
      echo "|---|---|---|"
      printf '%s\n' "${summary_rows[@]}"
      echo ""
    } >> "$summary_target"
  fi
done

{
  echo "paths<<LOCKFILES_EOF"
  printf '%s\n' "${lockfiles[@]}"
  echo "LOCKFILES_EOF"
} >> "$output_target"

echo "==> Done. Refreshed: ${lockfiles[*]}"
