# GoML installer

Install the [GoML](https://github.com/gomlang/goml) toolchain on Linux amd64 or macOS arm64.

## Install

Install Go 1.26 or newer and make it available on `PATH`. The installer also requires a POSIX shell, curl, tar, and sha256sum or shasum.

```sh
curl -fsSL https://gomlang.github.io/install/install.sh | sh
export PATH="${GOML_HOME:-$HOME/.goml}/bin:$PATH"
goml version
```

The script selects the latest published release from `gomlang/goml`, verifies its archive against that release's `SHA256SUMS`, and initializes the toolchain. The installation directory defaults to `${GOML_HOME:-$HOME/.goml}`. Add the PATH command printed by the installer to your shell configuration; the script does not modify shell configuration files.

To select a release and installation directory:

```sh
curl -fsSL https://gomlang.github.io/install/install.sh | sh -s -- --version X.Y.Z --prefix "$HOME/tools/goml"
```

`--version` also accepts a leading `v`. Pass `--help` after `sh -s --` for the available options.

Create and run a project after installation:

```sh
goml new hello
cd hello
goml run
```

## Upgrade

Run the installer again to install the latest release. It replaces the five GoML executables and the `builtin`, `prelude`, `std`, and `compiler` resource directories. Dependency caches, other executables, and unrelated files are preserved.

If replacement or initialization fails, the installer restores the previous toolchain. Concurrent installations into the same directory are rejected. After a forced termination, inspect the reported `.goml-install` directory and any backups before retrying. Keep the installation's `bin` and `lib` directories together when relocating it.

## Development

The installer itself runs with `sh`. Its tests use Bash. Run the deterministic tests without network access:

```sh
sh -n install.sh tests/fixtures/curl
bash -n tests/common.sh tests/install.sh tests/smoke.sh
bash tests/install.sh
```

To download and install a real release into a temporary directory, create a project, and check, build, run, and test it:

```sh
bash tests/smoke.sh
```

Pass `--version X.Y.Z` to the smoke test to select a release. Set `GOML_INSTALL_SCRIPT_URL` to test a hosted script. GitHub Actions runs both test suites on Linux amd64 and macOS arm64, publishes the tested installer to [GitHub Pages](https://gomlang.github.io/install/), and checks installation from the published URL.
