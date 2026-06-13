#!/bin/ash
# shellcheck shell=dash
# Custom CosmWasm optimizer entrypoint for workspaces with local sibling dependencies.
set -o errexit -o nounset -o pipefail
export PATH="$PATH:/root/.cargo/bin"
# Resolve the workspace subdirectory
# === Resolve project directory inside container ===
# Resolve the workspace subdirectory
WORKSPACE_ROOT="/workspace"
HOST_PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"   # full container path passed via env

# Use PROJECT_DIR directly — the volume is mounted at /workspace/<repo-root>
# and PROJECT_DIR is the full path within that volume.
PROJECT_DIR="$HOST_PROJECT_DIR"
PROJECT_BASENAME=$(basename "$PROJECT_DIR")

if [ ! -d "$PROJECT_DIR" ]; then
    echo "ERROR: Project directory $PROJECT_DIR does not exist." >&2
    echo "Host path was: $HOST_PROJECT_DIR" >&2
    echo "Make sure to mount the parent directory tree at /workspace." >&2
    exit 1
fi

if [ ! -f "$PROJECT_DIR/Cargo.toml" ]; then
    echo "ERROR: No Cargo.toml found at $PROJECT_DIR" >&2
    exit 1
fi  
echo "=== DAO Custom Optimizer ==="
echo "Workspace root: $WORKSPACE_ROOT"
echo "Project basename: $PROJECT_BASENAME"
echo "Project dir: $PROJECT_DIR"
echo "Host project dir: $HOST_PROJECT_DIR"

# === Resolve workspace root ===
# Walk up from PROJECT_DIR to find the nearest Cargo.toml with [workspace].
# This ensures bob runs from the correct level so all path dependencies
# (whether one level or two levels deep) resolve via cargo's workspace resolution.
WORKSPACE_ROOT_DIR="$PROJECT_DIR"
while [ "$WORKSPACE_ROOT_DIR" != "/" ]; do
  if [ -f "$WORKSPACE_ROOT_DIR/Cargo.toml" ] && grep -q '\[workspace\]' "$WORKSPACE_ROOT_DIR/Cargo.toml" 2>/dev/null; then
    echo "Workspace root found: $WORKSPACE_ROOT_DIR"
    break
  fi
  WORKSPACE_ROOT_DIR=$(dirname "$WORKSPACE_ROOT_DIR")
done
if [ "$WORKSPACE_ROOT_DIR" = "/" ]; then
  echo "No workspace Cargo.toml found — using PROJECT_DIR directly"
  WORKSPACE_ROOT_DIR="$PROJECT_DIR"
fi

rustup toolchain list
cargo --version

mkdir -p "$PROJECT_DIR/artifacts"
rm -f /target/wasm32-unknown-unknown/release/*.wasm

# # === Pin tokio without net feature for wasm compatibility ===
# # Some workspace deps (cosmrs → tendermint-rpc → async-tungstenite → tokio)
# # pull in tokio's default features (includes "net" → mio) which don't compile
# # for wasm32-unknown-unknown. Ensure tokio in workspace.dependencies has
# # default-features = false so contracts build cleanly for wasm.
# WORKSPACE_CARGO="$WORKSPACE_ROOT_DIR/Cargo.toml"
# if [ -f "$WORKSPACE_CARGO" ]; then
#   if grep -q '^tokio.*=.*version' "$WORKSPACE_CARGO"; then
#     echo "  tokio already defined in workspace.dependencies — checking default-features..."
#     if grep -q '^tokio.*default-features.*false' "$WORKSPACE_CARGO"; then
#       echo "  ✓ tokio already has default-features = false"
#     else
#       echo "  ⚠ tokio has default-features = true (may cause mio/wasm errors)"
#     fi
#   else
#     echo "  ⚠ tokio not found in workspace.dependencies — add it if contracts pull in tokio"
#   fi
# fi

# Hide excluded crates from bob's filesystem scanner
EXCLUDED_CRATES="${EXCLUDED_CRATES:-}"
STASH_DIR="/tmp/_infuser_optimizer_stash"
RESTORE=0

for crate in $EXCLUDED_CRATES; do
  CRATE_PATH="$WORKSPACE_ROOT_DIR/contracts/external/$crate"
  if [ -d "$CRATE_PATH" ]; then
    echo "Stashing excluded crate: $crate"
    mkdir -p "$STASH_DIR"
    mv "$CRATE_PATH" "$STASH_DIR/"
    RESTORE=1
  fi
done

echo "Building project (from workspace root: $WORKSPACE_ROOT_DIR) ..."
(
  cd "$WORKSPACE_ROOT_DIR"
  /usr/local/bin/bob .
)
BUILD_EXIT=$?

if [ "$RESTORE" -eq 1 ]; then
  echo "Restoring stashed crates ..."
  for crate in "$STASH_DIR"/*; do
    [ -d "$crate" ] && mv "$crate" "$PROJECT_DIR/contracts/external/"
  done
  rmdir "$STASH_DIR" 2>/dev/null || true
fi

if [ "$BUILD_EXIT" -ne 0 ]; then
  exit $BUILD_EXIT
fi

# Optimize: run wasm-opt on each built .wasm
# Rust 1.78+ produces Wasm with bulk memory operations (memory.copy, memory.fill).
# These require CosmWasm 3.0+ on chain. We enable bulk memory in wasm-opt so it
# accepts the Wasm — there is no way to strip these from the std library without
# -Z build-std.
echo "Optimizing artifacts ..."
for WASM in /target/wasm32-unknown-unknown/release/*.wasm; do
  [ -e "$WASM" ] || continue

  OUT_FILENAME=$(basename "$WASM")
  echo "Optimizing $OUT_FILENAME ..."
  wasm-opt -Os --enable-bulk-memory "$WASM" -o "$PROJECT_DIR/artifacts/$OUT_FILENAME"
done

echo "Post-processing artifacts..."
(
  cd "$PROJECT_DIR/artifacts"
  if test -n "$(find . -maxdepth 1 -name '*.wasm' -print -quit)"; then
    sha256sum -- *.wasm | tee checksums.txt
  else
    echo "Warn: No .wasm file built." >&2
  fi
)

echo "Done."