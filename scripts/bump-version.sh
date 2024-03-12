#!/bin/bash
set -eux

SCRIPT_DIR="$(dirname "$0")"
cd $SCRIPT_DIR/..

OLD_VERSION="${1}"
NEW_VERSION="${2}"

echo "Current version: $OLD_VERSION"
echo "Bumping version: $NEW_VERSION"

function replace() {
    local _path="$3"

    if grep "$2" "$_path" >/dev/null; then
        echo "Version already bumped to $NEW_VERSION"
        exit 1
    fi

    perl -i -pe "s/$1/$2/g" "$3"

    # Verify that replacement was successful
    if ! grep "$2" "$3"; then
        echo "Failed to bump version"
        exit 1
    fi
}

replace "\@version \"[0-9.rc\-]+\"" "\@version \"$NEW_VERSION\"" ./mix.exs
