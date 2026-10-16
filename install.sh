#!/bin/sh

set -eu

fail() {
    printf 'goml installer: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'USAGE'
Usage: sh install.sh [--version X.Y.Z] [--prefix DIR]

Install the latest GoML release for Linux amd64 or macOS arm64.
Requires Go 1.26+, curl, tar, and sha256sum or shasum.

  --version X.Y.Z  Install a specific release (an optional v prefix is accepted)
  --prefix DIR     Install under DIR (default: $GOML_HOME or $HOME/.goml)
  -h, --help       Show this help
USAGE
}

download() {
    curl --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --fail --silent --show-error --location --retry 3 "$@"
}

checksum() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$@"
    else
        shasum -a 256 "$@"
    fi
}

cleanup() {
    install_status=$?
    trap - 0 HUP INT TERM
    set +e
    restore_failed=0
    if test "$install_complete" = 0; then
        for entry in $managed_paths; do
            if test -e "$temporary/previous/$entry" || test -L "$temporary/previous/$entry"; then
                if ! rm -rf "$prefix/$entry" \
                    || ! mv "$temporary/previous/$entry" "$prefix/$entry"; then
                    restore_failed=1
                fi
            elif test -f "$temporary/replacing-${entry##*/}"; then
                if ! rm -rf "$prefix/$entry"; then
                    restore_failed=1
                fi
            fi
        done
    fi
    if test "$restore_failed" = 0; then
        rm -rf "$temporary"
    else
        printf 'goml installer: could not restore the previous installation; backups remain in %s\n' \
            "$temporary/previous" >&2
        install_status=1
    fi
    exit "$install_status"
}

main() {
    release_version=
    prefix=${GOML_HOME:-}
    while test "$#" -gt 0; do
        case "$1" in
            --version)
                test "$#" -ge 2 || fail '--version requires a value'
                test -n "$2" || fail '--version requires a value'
                release_version=${2#v}
                shift 2
                ;;
            --prefix)
                test "$#" -ge 2 || fail '--prefix requires a value'
                test -n "$2" || fail '--prefix requires a value'
                prefix=$2
                shift 2
                ;;
            -h|--help) usage; exit 0 ;;
            *) fail "unknown argument: $1" ;;
        esac
    done

    if test -z "$prefix"; then
        test -n "${HOME:-}" || fail 'set HOME, GOML_HOME, or --prefix to select an installation directory'
        prefix=$HOME/.goml
    fi

    for required_command in curl tar awk sed uname go; do
        command -v "$required_command" >/dev/null 2>&1 || fail "required command not found: $required_command"
    done
    if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
        fail 'install sha256sum or shasum before continuing'
    fi
    host_os=$(uname -s)
    host_arch=$(uname -m)
    case "$host_os/$host_arch" in
        Linux/x86_64) platform=linux-amd64 ;;
        Darwin/arm64) platform=darwin-arm64 ;;
        *) fail "unsupported platform: $host_os/$host_arch; supported: Linux amd64, macOS arm64" ;;
    esac
    go_version=$(GOTOOLCHAIN=local go version) || fail 'could not determine the Go version'
    if ! printf '%s\n' "$go_version" | awk '
        $1 == "go" && $2 == "version" && $3 ~ /^go[0-9]+\.[0-9]+/ {
            sub(/^go/, "", $3)
            split($3, parts, ".")
            valid = parts[1] > 1 || (parts[1] == 1 && parts[2] + 0 >= 26)
        }
        END { exit !valid }
    '; then
        fail "Go 1.26 or newer must be on PATH; found: $go_version"
    fi

    releases=https://github.com/gomlang/goml/releases
    if test -z "$release_version"; then
        latest_url=$(download --output /dev/null --write-out '%{url_effective}' "$releases/latest") \
            || fail 'could not find the latest release'
        case "$latest_url" in
            "$releases/tag/v"*) release_version=${latest_url##*/v} ;;
            *) fail "unexpected release URL: $latest_url" ;;
        esac
    fi
    printf '%s\n' "$release_version" | awk '
        /^[0-9]+\.[0-9]+\.[0-9]+$/ { valid = 1 }
        END { exit !(NR == 1 && valid) }
    ' || fail "invalid release version: $release_version"

    case "$prefix" in
        /*) ;;
        *) prefix=$PWD/$prefix ;;
    esac
    mkdir -p "$prefix"
    prefix=$(CDPATH= cd "$prefix" && pwd -P)
    test "$prefix" != / || fail 'the installation prefix cannot be /'
    if test -f "$prefix/gomlc/goml.toml" && test -f "$prefix/goml/goml.toml"; then
        fail 'cannot install over a GoML source checkout'
    fi
    for directory in bin lib; do
        test ! -L "$prefix/$directory" || fail "$prefix/$directory must not be a symbolic link"
        if test -e "$prefix/$directory" && test ! -d "$prefix/$directory"; then
            fail "$prefix/$directory must be a directory"
        fi
    done
    temporary=$prefix/.goml-install
    (umask 077; mkdir "$temporary") \
        || fail "another installation may be running; inspect $temporary before retrying"
    install_complete=0
    managed_paths='bin/goml bin/gomlc bin/gomlfmt bin/gomldoc bin/gomllsp lib/builtin lib/prelude lib/std lib/compiler'
    trap cleanup 0
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    package=goml-$release_version-$platform
    archive=$package.tar.gz
    printf 'Downloading GoML %s for %s...\n' "$release_version" "$platform"
    download --output "$temporary/$archive" "$releases/download/v$release_version/$archive"
    download --output "$temporary/SHA256SUMS" "$releases/download/v$release_version/SHA256SUMS"
    awk -v archive="$archive" '
        $2 == archive {
            count++
            if (NF != 2 || length($1) != 64 || $1 ~ /[^0-9a-fA-F]/) invalid = 1
            print
        }
        END { if (count != 1 || invalid) exit 1 }
    ' "$temporary/SHA256SUMS" > "$temporary/archive.sha256" \
        || fail "SHA256SUMS must contain exactly one valid checksum for $archive"
    (cd "$temporary" && checksum -c archive.sha256) || fail 'archive checksum verification failed'

    tar -tzf "$temporary/$archive" > "$temporary/contents"
    awk -v package="$package" '
        $0 != package && index($0, package "/") != 1 { invalid = 1 }
        /(^|\/)\.\.(\/|$)/ { invalid = 1 }
        END { exit invalid }
    ' "$temporary/contents" || fail 'archive contains unexpected paths'
    tar -xzf "$temporary/$archive" -C "$temporary"
    extracted=$temporary/$package
    for tool in goml gomlc gomlfmt gomldoc gomllsp; do
        test -x "$extracted/bin/$tool" || fail "archive is missing bin/$tool"
    done
    for resource in builtin/goml.toml prelude/goml.toml std/goml.toml; do
        test -f "$extracted/lib/$resource" || fail "archive is missing lib/$resource"
    done
    test "$("$extracted/bin/goml" version)" = "goml $release_version" \
        || fail 'archive version does not match the requested release'

    mkdir -p "$prefix/bin" "$prefix/lib" "$temporary/previous/bin" "$temporary/previous/lib"
    mkdir -p "$extracted/lib/compiler"
    for entry in $managed_paths; do
        if test -e "$prefix/$entry" || test -L "$prefix/$entry"; then
            mv "$prefix/$entry" "$temporary/previous/$entry"
        fi
        : > "$temporary/replacing-${entry##*/}"
        mv "$extracted/$entry" "$prefix/$entry"
    done
    printf 'Initializing GoML in %s...\n' "$prefix"
    "$prefix/bin/goml" __toolchain-finalize --prefix "$prefix"
    set -- "$prefix"/lib/compiler/*.gaf
    test "$#" = 1 && test -f "$1" || fail 'toolchain initialization did not create exactly one compiler world'
    "$prefix/bin/goml" version
    install_complete=1
    path_entry=$(printf '%s' "$prefix/bin" | sed "s/'/'\\\\''/g")
    printf '\nInstalled GoML in %s\nAdd this line to your shell configuration:\n' "$prefix"
    printf "  export PATH='%s':%s\n" "$path_entry" '"$PATH"'
}

main "$@"
