#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary="$(mktemp -d)"
temporary="$(cd "$temporary" && pwd -P)"
trap 'rm -rf "$temporary"' EXIT
prefix="$temporary/toolchain"
export GOML_HOME="$temporary/home"

if test -n "${GOML_INSTALL_SCRIPT_URL:-}"; then
    curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors "$GOML_INSTALL_SCRIPT_URL" | sh -s -- "$@" --prefix "$prefix"
else
    cat "$repository_root/install.sh" | sh -s -- "$@" --prefix "$prefix"
fi
test ! -e "$prefix/.goml-install"
"$prefix/bin/goml" version
(
    cd "$temporary"
    "$prefix/bin/goml" new hello
    cd hello
    "$prefix/bin/goml" check
    "$prefix/bin/goml" build
    "$prefix/bin/goml" run
    "$prefix/bin/goml" test
)
printf '%s\n' 'installer smoke test passed'
