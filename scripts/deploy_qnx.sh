#!/usr/bin/env bash
# scripts/deploy_qnx.sh
#
# Deploy QNX build outputs + required runtime libs + run script to a QNX target over SSH/SCP.
#
# Remote layout:
#   <REMOTE_DIR>/
#     bin/   sender, receiver
#     lib/   libfastdds*, libfastcdr*, libfoonathan*, libtinyxml2*, libc++*, libgcc_s*, libcatalog.so.1, ...
#     etc/   fastdds_profiles.xml
#     run_qnx.sh
#     out/   (created)
#
# Usage:
#   source ~/qnx710/qnxsdp-env.sh
#   ./scripts/deploy_qnx.sh --target root@rr-scc --dir /opt/home/autodrive
#
# Options:
#   --no-libs     Skip copying qnx_stage libs
#   --no-sysrt    Skip copying sysroot runtime (libc++, libgcc_s, libcatalog)
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${BUILD_DIR:=build-qnx}"
: "${REMOTE_DIR:=/opt/home/autodrive}"
: "${NO_LIBS:=0}"
: "${NO_SYSRT:=0}"

TARGET=""

log() { printf "\n\033[1;34m==> %s\033[0m\n" "$*"; }
die() { printf "\n\033[1;31mERROR:\033[0m %s\n" "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    --dir) REMOTE_DIR="$2"; shift 2 ;;
    --no-libs) NO_LIBS=1; shift ;;
    --no-sysrt) NO_SYSRT=1; shift ;;
    -h|--help)
      cat <<EOF
Usage:
  $0 --target user@host [--dir /remote/path] [--no-libs] [--no-sysrt]

Env:
  BUILD_DIR=build-qnx  (default)
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
RUNSCRIPT="$ROOT_DIR/scripts/run_qnx.sh"

SENDER="$BUILD_ABS/sender"
RECEIVER="$BUILD_ABS/receiver"

[[ -d "$BUILD_ABS" ]] || die "Build dir not found: $BUILD_ABS (run scripts/build_qnx_app.sh first)"
[[ -f "$SENDER" ]] || die "Missing sender executable: $SENDER"
[[ -f "$RECEIVER" ]] || die "Missing receiver executable: $RECEIVER"
[[ -f "$PROFILES" ]] || die "Missing fastdds_profiles.xml at repo root: $PROFILES"
[[ -f "$RUNSCRIPT" ]] || die "Missing run script: $RUNSCRIPT"

# Optional shim lib (built in build dir)
SHIM="$(find "$BUILD_ABS" -maxdepth 3 -name "libfastdds_ipc_shim*.so*" 2>/dev/null | sed -n '1,1p' || true)"

log "Preparing remote dirs: $TARGET:$REMOTE_DIR/{bin,lib,etc,out}"
ssh "$TARGET" "mkdir -p '$REMOTE_DIR/bin' '$REMOTE_DIR/lib' '$REMOTE_DIR/etc' '$REMOTE_DIR/out'"

log "Copying executables -> bin/"
scp "$SENDER" "$RECEIVER" "$TARGET:$REMOTE_DIR/bin/"

log "Copying profiles -> etc/"
scp "$PROFILES" "$TARGET:$REMOTE_DIR/etc/"

log "Copying run_qnx.sh -> $REMOTE_DIR/"
scp "$RUNSCRIPT" "$TARGET:$REMOTE_DIR/run_qnx.sh"
ssh "$TARGET" "chmod +x '$REMOTE_DIR/run_qnx.sh'"

if [[ -n "$SHIM" && -f "$SHIM" ]]; then
  log "Copying shim -> lib/: $(basename "$SHIM")"
  scp "$SHIM" "$TARGET:$REMOTE_DIR/lib/"
else
  log "Note: shim library not found under $BUILD_ABS (skipping)."
fi

if [[ "$NO_LIBS" -eq 0 ]]; then
  [[ -d "$STAGE_LIB" ]] || die "Stage lib dir not found: $STAGE_LIB (run scripts/build_qnx_deps.sh first)"

  log "Copying runtime deps from qnx_stage/lib -> remote lib/"
  shopt -s nullglob
  LIBS=(
    "$STAGE_LIB"/libfastdds.so*
    "$STAGE_LIB"/libfastcdr.so*
    "$STAGE_LIB"/libfoonathan_memory*.so*
    "$STAGE_LIB"/libtinyxml2.so*
  )
  shopt -u nullglob

  [[ "${#LIBS[@]}" -gt 0 ]] || die "No matching libs found in $STAGE_LIB"
  scp "${LIBS[@]}" "$TARGET:$REMOTE_DIR/lib/"
else
  log "--no-libs set; skipping qnx_stage library copy"
fi

if [[ "$NO_SYSRT" -eq 0 ]]; then
  [[ -n "${QNX_TARGET:-}" ]] || die "QNX_TARGET not set. Run: source ~/qnx710/qnxsdp-env.sh"

  # libc++ (sysroot has libc++.so.1.0, target loader wants libc++.so.1)
  LIBCXX="$QNX_TARGET/aarch64le/usr/lib/libc++.so.1.0"
  [[ -f "$LIBCXX" ]] || die "Could not locate: $LIBCXX"
  log "Copying libc++ -> remote lib/ (and creating libc++.so.1 symlink)"
  scp "$LIBCXX" "$TARGET:$REMOTE_DIR/lib/"
  ssh "$TARGET" "cd '$REMOTE_DIR/lib' && ln -sf libc++.so.1.0 libc++.so.1"

  # libgcc_s (optional but common)
  LIBGCC="$QNX_TARGET/aarch64le/usr/lib/libgcc_s.so.1"
  [[ -f "$LIBGCC" ]] || LIBGCC="$QNX_TARGET/aarch64le/lib/libgcc_s.so.1"
  if [[ -f "$LIBGCC" ]]; then
    log "Copying libgcc_s.so.1 -> remote lib/"
    scp "$LIBGCC" "$TARGET:$REMOTE_DIR/lib/"
  else
    log "Note: libgcc_s.so.1 not found in sysroot (skipping)."
  fi

  # libcatalog.so.1 (your target is missing it)
  LIBCAT="$QNX_TARGET/aarch64le/lib/libcatalog.so.1"
  if [[ -f "$LIBCAT" ]]; then
    log "Copying libcatalog.so.1 -> remote lib/"
    scp "$LIBCAT" "$TARGET:$REMOTE_DIR/lib/"
  else
    log "WARN: libcatalog.so.1 not found at $LIBCAT (skipping)."
  fi
else
  log "--no-sysrt set; skipping sysroot runtime copy"
fi

cat <<EOF

==> Deployment complete.

On target (two terminals recommended):

  export TARGET_DIR=$REMOTE_DIR
  export LD_LIBRARY_PATH=\$TARGET_DIR/lib:\$TARGET_DIR/bin:/lib:/usr/lib:\$LD_LIBRARY_PATH
  export FASTDDS_DEFAULT_PROFILES_FILE=\$TARGET_DIR/etc/fastdds_profiles.xml

  # Terminal 1:
  \$TARGET_DIR/run_qnx.sh receiver

  # Terminal 2:
  \$TARGET_DIR/run_qnx.sh sender

CSV output (if enabled) will be under:
  \$TARGET_DIR/out/

Copy back to host:
  scp $TARGET:\$TARGET_DIR/out/*.csv $ROOT_DIR/out/

EOF
