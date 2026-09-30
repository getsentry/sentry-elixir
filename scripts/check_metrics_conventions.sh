#!/usr/bin/env bash

set -euo pipefail

repository="${CONVENTIONS_REPOSITORY:-getsentry/sentry-conventions}"
ref="${1:-${CONVENTIONS_REF:-feat/metric-model}}"
checkout="${CONVENTIONS_CHECKOUT:-tmp/sentry-conventions}"
definitions="test/fixtures/sentry_conventions/model"
minimum_node_major=22

cd "$(dirname "$0")/.."

for tool in git node; do
  if ! command -v "$tool" >/dev/null; then
    echo "$tool is required to check metrics against sentry-conventions" >&2
    exit 1
  fi
done

if [ ! -d "$checkout/.git" ]; then
  echo "==> Cloning $repository into $checkout"
  git clone --quiet --filter=blob:none "https://github.com/$repository.git" "$checkout"
fi

echo "==> Checking out $repository@$ref"
git -C "$checkout" fetch --quiet origin "$ref"
git -C "$checkout" checkout --quiet --force --detach FETCH_HEAD
git -C "$checkout" clean --quiet -fd -- model
echo "==> sentry-conventions at $(git -C "$checkout" rev-parse --short HEAD)"

node_runner=()
if [ "$(node -p 'process.versions.node.split(".")[0]')" -lt "$minimum_node_major" ]; then
  pinned_node=$(node -p "require('./$checkout/package.json').volta?.node || '$minimum_node_major'")

  if ! command -v mise >/dev/null; then
    echo "sentry-conventions needs Node.js $minimum_node_major or later (it pins $pinned_node), found $(node --version)" >&2
    exit 1
  fi

  echo "==> Using Node.js $pinned_node through mise, $(node --version) is too old for sentry-conventions"
  node_runner=(mise exec "node@$pinned_node" --)
fi

echo "==> Validating $definitions with the sentry-conventions tests"
cp -R "$definitions/." "$checkout/model/"
(
  cd "$checkout"
  export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
  "${node_runner[@]}" corepack yarn install --frozen-lockfile --silent
  "${node_runner[@]}" corepack yarn vitest run test/metrics.test.ts test/attributes.test.ts
)

echo "==> Checking emitted runtime metrics against $definitions"
SENTRY_CONVENTIONS_PATH="$checkout" MIX_ENV=test mix test test/sentry/metrics/runtime_conventions_test.exs
