#!/usr/bin/env bash

set -Eeuo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repository_root/tests/common.sh"
temporary="$(mktemp -d)"
temporary="$(cd "$temporary" && pwd -P)"
trap 'rm -rf "$temporary"' EXIT
trap 'printf "installer test failed at line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR
installer="$repository_root/install.sh"
prefix="$temporary/prefix with spaces and 'quote'"
export GOML_INSTALL_TEST_VERSION="$(cat "$repository_root/tests/fixtures/version")"
export GOML_INSTALL_TEST_RELEASE_DIR="$temporary/releases"
export GOML_INSTALL_TEST_DOWNLOADS="$temporary/downloads"
mkdir -p "$temporary/bin" "$GOML_INSTALL_TEST_RELEASE_DIR"
cp "$repository_root/tests/fixtures/curl" "$temporary/bin/curl"
cat > "$temporary/bin/uname" <<'UNAME'
#!/bin/sh
case "$1" in
    -s) printf '%s\n' "${GOML_INSTALL_TEST_OS:-Linux}" ;;
    -m) printf '%s\n' "${GOML_INSTALL_TEST_ARCH:-x86_64}" ;;
esac
UNAME
cat > "$temporary/bin/go" <<'GO'
#!/bin/sh
printf 'go version go%s linux/amd64\n' "${GOML_INSTALL_TEST_GO_VERSION:-1.26.0}"
GO
cat > "$temporary/driver" <<'DRIVER'
#!/bin/sh
set -eu
case "$1" in
    version) printf 'goml %s\n' "${GOML_INSTALL_TEST_BINARY_VERSION:-$GOML_INSTALL_TEST_VERSION}" ;;
    __toolchain-finalize)
        test "$2" = --prefix
        test "${GOML_INSTALL_TEST_FINALIZE_FAIL:-0}" = 0
        if test "${GOML_INSTALL_TEST_SKIP_WORLD:-0}" = 0; then
            mkdir -p "$3/lib/compiler"
            printf '%s\n' world > "$3/lib/compiler/${GOML_INSTALL_TEST_WORLD_NAME:-compiler-world.gaf}"
            if test "${GOML_INSTALL_TEST_EXTRA_WORLD:-0}" = 1; then
                printf '%s\n' world > "$3/lib/compiler/extra.gaf"
            fi
        fi
        ;;
    *) exit 1 ;;
esac
DRIVER
chmod +x "$temporary/bin/"* "$temporary/driver"
export PATH="$temporary/bin:$PATH"

for platform in linux-amd64 darwin-arm64; do
    package="goml-$GOML_INSTALL_TEST_VERSION-$platform"
    mkdir -p "$temporary/$package/bin" "$temporary/$package/lib/builtin" \
        "$temporary/$package/lib/prelude" "$temporary/$package/lib/std"
    for tool in goml gomlc gomlfmt gomldoc gomllsp; do
        cp "$temporary/driver" "$temporary/$package/bin/$tool"
    done
    for resource in builtin/goml.toml prelude/goml.toml std/goml.toml; do
        printf '%s\n' resource > "$temporary/$package/lib/$resource"
    done
    tar -czf "$GOML_INSTALL_TEST_RELEASE_DIR/$package.tar.gz" -C "$temporary" "$package"
done
(
    cd "$GOML_INSTALL_TEST_RELEASE_DIR"
    toolchain_sha256 ./*.tar.gz | sed 's|  \./|  |' > SHA256SUMS
)
cp "$GOML_INSTALL_TEST_RELEASE_DIR/SHA256SUMS" "$temporary/checksums"

sh "$installer" --help > "$temporary/help"
sh "$installer" --prefix "$prefix" > "$temporary/install.log"
test -f "$prefix/lib/compiler/compiler-world.gaf"
test ! -e "$prefix/.goml-install"
grep -F '/releases/latest' "$GOML_INSTALL_TEST_DOWNLOADS" >/dev/null
path_command="$(sed -n '/^  export PATH=/p' "$temporary/install.log")"
test "$(sh -c "$path_command; command -v goml")" = "$prefix/bin/goml"

GOML_INSTALL_TEST_WORLD_NAME=compiler-world-v2.gaf sh "$installer" \
    --version "$GOML_INSTALL_TEST_VERSION" --prefix "$temporary/previous-format" \
    > "$temporary/previous-format.log"
test -f "$temporary/previous-format/lib/compiler/compiler-world-v2.gaf"

mkdir -p "$prefix/cache" "$prefix/lib/custom"
printf '%s\n' retained > "$prefix/cache/retained"
printf '%s\n' retained > "$prefix/lib/custom/retained"
printf '%s\n' retained > "$prefix/bin/custom"
printf '%s\n' obsolete > "$prefix/lib/std/obsolete"
printf '%s\n' obsolete > "$prefix/lib/compiler/obsolete"
: > "$GOML_INSTALL_TEST_DOWNLOADS"
GOML_HOME="$prefix" sh "$installer" --version "v$GOML_INSTALL_TEST_VERSION" > "$temporary/upgrade.log"
test ! -e "$prefix/lib/std/obsolete"
test ! -e "$prefix/lib/compiler/obsolete"
test -f "$prefix/cache/retained"
test -f "$prefix/lib/custom/retained"
test -f "$prefix/bin/custom"
test "$(wc -l < "$GOML_INSTALL_TEST_DOWNLOADS" | tr -d ' ')" = 2

reject_install() {
    local name="$1"
    shift
    local before after
    before="$(toolchain_hash_files "$prefix")"
    if "$@" sh "$installer" --version "$GOML_INSTALL_TEST_VERSION" --prefix "$prefix" \
        > "$temporary/$name.stdout" 2> "$temporary/$name.stderr"; then
        printf 'expected installation failure: %s\n' "$name" >&2
        exit 1
    fi
    after="$(toolchain_hash_files "$prefix")"
    test "$before" = "$after"
    test ! -e "$prefix/.goml-install"
}

reject_install unsupported env GOML_INSTALL_TEST_ARCH=aarch64
reject_install old-go env GOML_INSTALL_TEST_GO_VERSION=1.25.8
reject_install download env GOML_INSTALL_TEST_DOWNLOAD_FAIL=1
reject_install version env GOML_INSTALL_TEST_BINARY_VERSION=invalid
reject_install finalize env GOML_INSTALL_TEST_FINALIZE_FAIL=1
reject_install missing-world env GOML_INSTALL_TEST_SKIP_WORLD=1
reject_install duplicate-world env GOML_INSTALL_TEST_EXTRA_WORLD=1

printf '%s\n' invalid > "$GOML_INSTALL_TEST_RELEASE_DIR/SHA256SUMS"
reject_install missing-checksum env
cat "$temporary/checksums" "$temporary/checksums" > "$GOML_INSTALL_TEST_RELEASE_DIR/SHA256SUMS"
reject_install duplicate-checksum env
cp "$temporary/checksums" "$GOML_INSTALL_TEST_RELEASE_DIR/SHA256SUMS"
archive="$GOML_INSTALL_TEST_RELEASE_DIR/goml-$GOML_INSTALL_TEST_VERSION-linux-amd64.tar.gz"
cp "$archive" "$temporary/archive"
printf '%s\n' corrupt >> "$archive"
reject_install checksum env
cp "$temporary/archive" "$archive"

mkdir -p "$temporary/unexpected/bin"
printf '%s\n' unexpected > "$temporary/unexpected/bin/goml"
tar -czf "$archive" -C "$temporary" unexpected
(
    cd "$GOML_INSTALL_TEST_RELEASE_DIR"
    toolchain_sha256 "${archive##*/}" > SHA256SUMS
)
reject_install archive-paths env
cp "$temporary/archive" "$archive"
cp "$temporary/checksums" "$GOML_INSTALL_TEST_RELEASE_DIR/SHA256SUMS"

package="goml-$GOML_INSTALL_TEST_VERSION-linux-amd64"
rm "$temporary/$package/lib/std/goml.toml"
tar -czf "$archive" -C "$temporary" "$package"
(
    cd "$GOML_INSTALL_TEST_RELEASE_DIR"
    toolchain_sha256 "${archive##*/}" > SHA256SUMS
)
reject_install missing-resource env
cp "$temporary/archive" "$archive"
cp "$temporary/checksums" "$GOML_INSTALL_TEST_RELEASE_DIR/SHA256SUMS"

export GOML_INSTALL_TEST_MV="$(command -v mv)"
export GOML_INSTALL_TEST_PREFIX="$prefix"
cat > "$temporary/bin/mv" <<'MV'
#!/bin/sh
case "$1" in
    */goml-*/lib/prelude)
        if test "$2" = "$GOML_INSTALL_TEST_PREFIX/lib/prelude"; then
            exit 1
        fi
        ;;
esac
exec "$GOML_INSTALL_TEST_MV" "$@"
MV
chmod +x "$temporary/bin/mv"
reject_install move env
rm "$temporary/bin/mv"

mkdir "$prefix/.goml-install"
printf '%s\n' retained > "$prefix/.goml-install/retained"
if sh "$installer" --version "$GOML_INSTALL_TEST_VERSION" --prefix "$prefix" \
    > "$temporary/locked.stdout" 2> "$temporary/locked.stderr"; then
    exit 1
fi
test -f "$prefix/.goml-install/retained"
rm -rf "$prefix/.goml-install"

for invalid_version in invalid '../invalid' $'1.2.3\ninvalid'; do
    if sh "$installer" --version "$invalid_version" --prefix "$prefix" \
        > "$temporary/invalid-version.stdout" 2> "$temporary/invalid-version.stderr"; then
        exit 1
    fi
done
mkdir -p "$temporary/checkout/gomlc" "$temporary/checkout/goml"
touch "$temporary/checkout/gomlc/goml.toml" "$temporary/checkout/goml/goml.toml"
if sh "$installer" --version "$GOML_INSTALL_TEST_VERSION" --prefix "$temporary/checkout" \
    > "$temporary/checkout.stdout" 2> "$temporary/checkout.stderr"; then
    exit 1
fi
test ! -e "$temporary/checkout/bin"
mkdir -p "$temporary/symlink-prefix" "$temporary/shared-bin"
ln -s "$temporary/shared-bin" "$temporary/symlink-prefix/bin"
if sh "$installer" --version "$GOML_INSTALL_TEST_VERSION" --prefix "$temporary/symlink-prefix" \
    > "$temporary/symlink.stdout" 2> "$temporary/symlink.stderr"; then
    exit 1
fi
test -L "$temporary/symlink-prefix/bin"
test ! -e "$temporary/shared-bin/goml"

mkdir "$temporary/fallback-bin"
for tool in sh curl go uname tar awk sed mkdir rm mv cp gzip shasum; do
    ln -s "$(command -v "$tool")" "$temporary/fallback-bin/$tool"
done
env PATH="$temporary/fallback-bin" GOML_INSTALL_TEST_OS=Darwin GOML_INSTALL_TEST_ARCH=arm64 \
    sh "$installer" --version "$GOML_INSTALL_TEST_VERSION" --prefix "$temporary/mac" \
    > "$temporary/mac.log"
test -f "$temporary/mac/lib/compiler/compiler-world.gaf"
grep -F "goml-$GOML_INSTALL_TEST_VERSION-darwin-arm64.tar.gz" "$GOML_INSTALL_TEST_DOWNLOADS" >/dev/null
printf '%s\n' 'installer tests passed'
