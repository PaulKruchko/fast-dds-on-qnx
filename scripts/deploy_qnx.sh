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
#   --no-sysrt    Skip copying sysroot runtime (libc++, libgcc_s, libcatalog, and auto-missing-lib fixups)
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${BUILD_DIR:=build-qnx}"
: "${REMOTE_DIR:=/opt/home/autodrive}"
: "${NO_LIBS:=0}"
: "${NO_SYSRT:=0}"

TARGET=""

log() { printf "\n\033[1;34m==> %s\033[0m\n" "$*"; }
warn() { printf "\n\033[1;33mWARN:\033[0m %s\n" "$*" >&2; }
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

ssh_mkdirs() {
  log "Preparing remote dirs: $TARGET:$REMOTE_DIR/{bin,lib,etc,out}"
  ssh "$TARGET" "mkdir -p '$REMOTE_DIR/bin' '$REMOTE_DIR/lib' '$REMOTE_DIR/etc' '$REMOTE_DIR/out'"
}

scp_into() {
  local src="$1"
  local dst="$2"
  scp "$src" "$TARGET:$dst"
}

remote_ld_library_path() {
  # Put our bundle first; keep common system locations too.
  printf "%s" "$REMOTE_DIR/lib:$REMOTE_DIR/bin:/proc/boot:/lib:/usr/lib:/lib/dll:/lib/dll/pci"
}

remote_ldd() {
  # Run ldd on target with our bundle LD_LIBRARY_PATH so it finds copied libs.
  local rpath
  rpath="$(remote_ld_library_path)"
  ssh "$TARGET" "export LD_LIBRARY_PATH='$rpath'; ldd '$REMOTE_DIR/bin/receiver' 2>&1 || true"
}

parse_missing_libs() {
  # Extract libs reported as missing by QNX ldd.
  # Handles both:
  #   libX.so.Y => unable to load
  #   ldd:FATAL: Could not load library libX.so.Y
  awk '
    /=> unable to load/ { print $1 }
    /ldd:FATAL: Could not load library/ { print $NF }
  ' | sed 's/[[:space:]]*$//' | sort -u
}

locate_sysroot_lib() {
  local lib="$1"
  local base="$QNX_TARGET/aarch64le"
  local hit=""

  # Fast paths
  for d in "$base/lib" "$base/usr/lib" "$base/lib/dll" "$base/usr/lib/dll"; do
    if [[ -f "$d/$lib" ]]; then
      hit="$d/$lib"; break
    fi
  done

  # Fallback search (still constrained to aarch64le sysroot)
  if [[ -z "$hit" ]]; then
    hit="$(find "$base" -type f -name "$lib" 2>/dev/null | sed -n '1,1p' || true)"
  fi

  printf "%s" "$hit"
}

copy_one_sysroot_lib() {
  local lib="$1"
  local p
  p="$(locate_sysroot_lib "$lib")"
  if [[ -n "$p" && -f "$p" ]]; then
    log "Copying sysroot lib -> remote lib/: $lib  (from $(dirname "$p"))"
    scp "$p" "$TARGET:$REMOTE_DIR/lib/"
    return 0
  else
    warn "Could not locate $lib in sysroot ($QNX_TARGET/aarch64le)."
    return 1
  fi
}

copy_sysroot_runtime_basics() {
  [[ -n "${QNX_TARGET:-}" ]] || die "QNX_TARGET not set. Run: source ~/qnx710/qnxsdp-env.sh"

  # libc++ (sysroot has libc++.so.1.0, loader wants libc++.so.1)
  local libcxx="$QNX_TARGET/aarch64le/usr/lib/libc++.so.1.0"
  [[ -f "$libcxx" ]] || die "Could not locate: $libcxx"
  log "Copying libc++ -> remote lib/ (and creating libc++.so.1 symlink)"
  scp "$libcxx" "$TARGET:$REMOTE_DIR/lib/"
  ssh "$TARGET" "cd '$REMOTE_DIR/lib' && ln -sf libc++.so.1.0 libc++.so.1"

  # libgcc_s (optional but common)
  local libgcc="$QNX_TARGET/aarch64le/usr/lib/libgcc_s.so.1"
  [[ -f "$libgcc" ]] || libgcc="$QNX_TARGET/aarch64le/lib/libgcc_s.so.1"
  if [[ -f "$libgcc" ]]; then
    log "Copying libgcc_s.so.1 -> remote lib/"
    scp "$libgcc" "$TARGET:$REMOTE_DIR/lib/"
  else
    warn "libgcc_s.so.1 not found in sysroot (skipping). If you later see __gxx_personality_v0, revisit."
  fi

  # libcatalog.so.1 (your target was missing it)
  local libcat="$QNX_TARGET/aarch64le/lib/libcatalog.so.1"
  if [[ -f "$libcat" ]]; then
    log "Copying libcatalog.so.1 -> remote lib/"
    scp "$libcat" "$TARGET:$REMOTE_DIR/lib/"
  else
    warn "libcatalog.so.1 not found at $libcat (skipping)."
  fi
}

autofix_missing_libs_from_sysroot() {
  log "Checking target for missing runtime libs (ldd)"
  local out missing
  out="$(remote_ldd)"
  echo "$out" | sed -n '1,120p' || true

  missing="$(echo "$out" | parse_missing_libs || true)"
  if [[ -z "$missing" ]]; then
    log "ldd reports no missing libs. ✅"
    return 0
  fi

  log "ldd reports missing libs:"
  echo "$missing" | sed 's/^/  - /'

  while read -r lib; do
    [[ -n "$lib" ]] || continue

    # Skip some libs that are typically /proc/boot on QNX (avoid pointless copies)
    case "$lib" in
      libc.so.*|libm.so.*|libsocket.so.*|libauditQnxSystem.so) continue ;;
    esac

    copy_one_sysroot_lib "$lib" || true
  done <<< "$missing"

  log "Re-checking ldd after sysroot autofix"
  out="$(remote_ldd)"
  missing="$(echo "$out" | parse_missing_libs || true)"
  if [[ -n "$missing" ]]; then
    warn "Still missing libs after sysroot copy:"
    echo "$missing" | sed 's/^/  - /'
    warn "You may need additional packages on target, or those libs live outside $QNX_TARGET/aarch64le."
  else
    log "All missing libs resolved. ✅"
  fi
}

# ------------------ Deploy ------------------
ssh_mkdirs

log "Copying executables -> bin/"
scp_into "$SENDER" "$REMOTE_DIR/bin/"
scp_into "$RECEIVER" "$REMOTE_DIR/bin/"

log "Copying profiles -> etc/"
scp_into "$PROFILES" "$REMOTE_DIR/etc/fastdds_profiles.xml"

log "Copying run_qnx.sh -> $REMOTE_DIR/"
scp_into "$RUNSCRIPT" "$REMOTE_DIR/run_qnx.sh"
ssh "$TARGET" "chmod +x '$REMOTE_DIR/run_qnx.sh'"

if [[ -n "$SHIM" && -f "$SHIM" ]]; then
  log "Copying shim -> lib/: $(basename "$SHIM")"
  scp_into "$SHIM" "$REMOTE_DIR/lib/"
else
  warn "Shim library not found under $BUILD_ABS (skipping). If sender/receiver link it dynamically, deploy it."
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
  copy_sysroot_runtime_basics
  autofix_missing_libs_from_sysroot
else
  log "--no-sysrt set; skipping sysroot runtime copy + autofix"
fi

cat <<EOF

==> Deployment complete.

On target (two terminals recommended):

  export TARGET_DIR=$REMOTE_DIR
  export LD_LIBRARY_PATH=\$TARGET_DIR/lib:\$TARGET_DIR/bin:/proc/boot:/lib:/usr/lib:\$LD_LIBRARY_PATH
  export FASTDDS_DEFAULT_PROFILES_FILE=\$TARGET_DIR/etc/fastdds_profiles.xml

  # Terminal 1:
  \$TARGET_DIR/run_qnx.sh receiver

  # Terminal 2:
  CAPTURE_CSV=1 \$TARGET_DIR/run_qnx.sh sender

CSV output will be under:
  \$TARGET_DIR/out/

Pull CSV back from the HOST (recommended):
  mkdir -p "$ROOT_DIR/results"
  scp $TARGET:$REMOTE_DIR/out/*.csv "$ROOT_DIR/results/"

EOF
