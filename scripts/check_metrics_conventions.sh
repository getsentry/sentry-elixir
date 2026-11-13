#!/usr/bin/env bash

set -euo pipefail

repository="${CONVENTIONS_REPOSITORY:-getsentry/sentry-conventions}"
ref="${1:-${CONVENTIONS_REF:-main}}"
checkout="${CONVENTIONS_CHECKOUT:-tmp/sentry-conventions}"

cd "$(dirname "$0")/.."

if [ ! -d "$checkout/.git" ]; then
  echo "==> Cloning $repository into $checkout"
  git clone --quiet --filter=blob:none "https://github.com/$repository.git" "$checkout"
fi

echo "==> Checking out $repository@$ref"
git -C "$checkout" fetch --quiet origin "$ref"
git -C "$checkout" checkout --quiet --force --detach FETCH_HEAD
git -C "$checkout" clean --quiet -fd -- model
echo "==> sentry-conventions at $(git -C "$checkout" rev-parse --short HEAD)"

echo "==> Checking emitted runtime metrics against $repository@$ref"
SENTRY_CONVENTIONS_PATH="$checkout" MIX_ENV=test mix test test/sentry/metrics/runtime_conventions_test.exs
