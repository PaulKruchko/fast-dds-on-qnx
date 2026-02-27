#!/usr/bin/env bash
# scripts/deploy_qnx.sh
#
# Deploy QNX build outputs + required runtime libs to a QNX target over SSH/SCP.
#
# What it copies:
#   - sender + receiver executables (from BUILD_DIR)
#   - shim library (if present): libfastdds_ipc_shim*.so (from BUILD_DIR)
#   - fastdds_profiles.xml (repo root)
#   - runtime deps from qnx_stage/lib:
#       libfastdds.so*, libfastcdr.so*, libfoonathan_memory*.so*, libtinyxml2.so*
#
# Usage:
#   ./scripts/deploy_qnx.sh --target root@192.168.1.50
#
# Optional:
#   ./scripts/deploy_qnx.sh --target root@192.168.1.50 --dir /tmp/ipcbench
#   BUILD_DIR=build-qnx ./scripts/deploy_qnx.sh --target root@192.168.1.50
#   ./scripts/deploy_qnx.sh --target root@192.168.1.50 --no-libs   # if target already has libs
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${BUILD_DIR:=build-qnx}"
: "${REMOTE_DIR:=/tmp/ipcbench}"
: "${NO_LIBS:=0}"

TARGET=""

log() { printf "\n\033[1;34m==> %s\033[0m\n" "$*"; }
die() { printf "\n\033[1;31mERROR:\033[0m %s\n" "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    --dir) REMOTE_DIR="$2"; shift 2 ;;
    --no-libs) NO_LIBS=1; shift ;;
    -h|--help)
      cat <<EOF
Usage:
  $0 --target user@host [--dir /remote/path] [--no-libs]

Env:
  BUILD_DIR=build-qnx   (default)
EOF
      exit 0
      ;;
    *) die "Unknown arg: $1" ;;
  esac
done

[[ -n "$TARGET" ]] || die "--target user@host is required"

BUILD_ABS="$ROOT_DIR/$BUILD_DIR"
STAGE_LIB="$ROOT_DIR/qnx_stage/lib"
PROFILES="$ROOT_DIR/fastdds_profiles.xml"

[[ -d "$BUILD_ABS" ]] || die "Build dir not found: $BUILD_ABS (run scripts/build_qnx_app.sh first)"
[[ -d "$STAGE_LIB" ]] || die "Stage lib dir not found: $STAGE_LIB (run scripts/build_qnx_deps.sh first)"
[[ -f "$PROFILES" ]] || die "Missing fastdds_profiles.xml at repo root: $PROFILES"

SENDER="$BUILD_ABS/sender"
RECEIVER="$BUILD_ABS/receiver"

[[ -f "$SENDER" ]] || die "Missing sender executable: $SENDER"
[[ -f "$RECEIVER" ]] || die "Missing receiver executable: $RECEIVER"

# Optional shim lib (name may vary depending on your CMake)
SHIM_CANDIDATES=(
  "$BUILD_ABS/libfastdds_ipc_shim.so"
  "$BUILD_ABS/libfastdds_ipc_shim.so.0"
  "$BUILD_ABS/libfastdds_ipc_shim.so.0.0.0"
)
SHIM=""
for f in "${SHIM_CANDIDATES[@]}"; do
  if [[ -f "$f" ]]; then SHIM="$f"; break; fi
done

# If you build the shim as part of the app, it may live elsewhere; also try a find:
if [[ -z "$SHIM" ]]; then
  SHIM="$(find "$BUILD_ABS" -maxdepth 3 -name "libfastdds_ipc_shim*.so*" 2>/dev/null | head -n 1 || true)"
fi

log "Preparing remote dir: $TARGET:$REMOTE_DIR"
ssh "$TARGET" "mkdir -p '$REMOTE_DIR' '$REMOTE_DIR/lib'"

log "Copying executables + profiles"
scp "$SENDER" "$RECEIVER" "$PROFILES" "$TARGET:$REMOTE_DIR/"

if [[ -n "$SHIM" ]]; then
  log "Copying shim: $(basename "$SHIM")"
  scp "$SHIM" "$TARGET:$REMOTE_DIR/lib/"
else
  log "Note: shim library not found in $BUILD_ABS (skipping). If your sender/receiver link it, locate it and scp it into $REMOTE_DIR/lib."
fi

if [[ "$NO_LIBS" -eq 0 ]]; then
  log "Copying runtime deps from qnx_stage/lib -> remote lib/"

  # Copy only what we need (and their symlinks if present)
  shopt -s nullglob
  LIBS=(
    "$STAGE_LIB"/libfastdds.so*
    "$STAGE_LIB"/libfastcdr.so*
    "$STAGE_LIB"/libfoonathan_memory*.so*
    "$STAGE_LIB"/libtinyxml2.so*
  )
  shopt -u nullglob

  [[ "${#LIBS[@]}" -gt 0 ]] || die "No matching libs found in $STAGE_LIB"

  # scp each file (preserves symlinks poorly; easiest is to copy all .so* in each family)
  scp "${LIBS[@]}" "$TARGET:$REMOTE_DIR/lib/"
else
  log "--no-libs set; skipping library copy"
fi

cat <<EOF

==> Deployment complete.

On target, run:

  cd $REMOTE_DIR
  export LD_LIBRARY_PATH=\$PWD/lib:\$LD_LIBRARY_PATH
  export FASTDDS_DEFAULT_PROFILES_FILE=\$PWD/fastdds_profiles.xml

  # Terminal 1:
  ./receiver

  # Terminal 2:
  ./sender > fastdds.csv

Then copy CSV back to host:

  scp $TARGET:$REMOTE_DIR/fastdds.csv $ROOT_DIR/results/

EOF
