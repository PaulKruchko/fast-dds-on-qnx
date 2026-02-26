#!/usr/bin/env bash
# scripts/build_qnx_deps.sh
#
# Build + install Fast DDS dependencies into a staging prefix for QNX aarch64le.
#
# Usage:
#   source ~/qnx710/qnxsdp-env.sh
#   ./scripts/build_qnx_deps.sh
#
# Optional overrides:
#   QNX_STAGE=/abs/path/to/qnx_stage ./scripts/build_qnx_deps.sh
#   FOONATHAN_DIR=~/foonathan_memory FASTCDR_DIR=~/Fast-CDR FASTDDS_DIR=~/Fast-DDS ./scripts/build_qnx_deps.sh
#   ASIO_DIR=~/asio TINYXML2_DIR=~/tinyxml2 ./scripts/build_qnx_deps.sh
#   BUILD_TYPE=Debug ./scripts/build_qnx_deps.sh
#   BUILD_SHARED_LIBS=OFF ./scripts/build_qnx_deps.sh
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLCHAIN_FILE="${ROOT_DIR}/qnx.toolchain.cmake"

# Force repo-local stage by default.
# If you want a different stage location, set QNX_STAGE_OVERRIDE for this invocation:
#   QNX_STAGE_OVERRIDE=/abs/path ./scripts/build_qnx_deps.sh
QNX_STAGE_DEFAULT="${ROOT_DIR}/qnx_stage"
: "${QNX_STAGE_OVERRIDE:=${QNX_STAGE_DEFAULT}}"
QNX_STAGE="${QNX_STAGE_OVERRIDE}"
export QNX_STAGE
: "${BUILD_TYPE:=Release}"
: "${BUILD_SHARED_LIBS:=ON}"
: "${JOBS:=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"

log() { printf "\n\033[1;34m==> %s\033[0m\n" "$*"; }
die() { printf "\n\033[1;31mERROR:\033[0m %s\n" "$*" >&2; exit 1; }

require_file() { [[ -f "$1" ]] || die "Missing file: $1"; }
require_dir() { [[ -d "$1" ]] || die "Missing directory: $1"; }
require_env() { [[ -n "${!1:-}" ]] || die "Missing env var $1. Did you run: source ~/qnx710/qnxsdp-env.sh ?"; }

log "Checking environment"
require_env QNX_HOST
require_env QNX_TARGET
command -v qcc >/dev/null 2>&1 || die "qcc not found in PATH. Did you source the QNX SDP env?"
require_file "${TOOLCHAIN_FILE}"

# Confirm qcc supports aarch64le variants (informational)
if ! qcc -V 2>&1 | grep -q "gcc_ntoaarch64le"; then
  die "qcc does not list gcc_ntoaarch64le. Your QNX install/toolchain may not include aarch64le."
fi

log "Using staging prefix: ${QNX_STAGE}"
mkdir -p "${QNX_STAGE}"

# -------------------------
# Dependency source dirs
# -------------------------
: "${FOONATHAN_DIR:=${ROOT_DIR}/foonathan_memory}"
: "${FASTCDR_DIR:=${ROOT_DIR}/Fast-CDR}"
: "${FASTDDS_DIR:=${ROOT_DIR}/Fast-DDS}"
: "${ASIO_DIR:=${ROOT_DIR}/asio}"
: "${TINYXML2_DIR:=${ROOT_DIR}/tinyxml2}"

if [[ ! -d "$FOONATHAN_DIR" && -d "${ROOT_DIR}/../foonathan_memory" ]]; then FOONATHAN_DIR="${ROOT_DIR}/../foonathan_memory"; fi
if [[ ! -d "$FASTCDR_DIR"   && -d "${ROOT_DIR}/../Fast-CDR" ]]; then FASTCDR_DIR="${ROOT_DIR}/../Fast-CDR"; fi
if [[ ! -d "$FASTDDS_DIR"   && -d "${ROOT_DIR}/../Fast-DDS" ]]; then FASTDDS_DIR="${ROOT_DIR}/../Fast-DDS"; fi

if [[ ! -d "$ASIO_DIR"      && -d "${ROOT_DIR}/../asio" ]]; then ASIO_DIR="${ROOT_DIR}/../asio"; fi
if [[ ! -d "$ASIO_DIR"      && -d "${ROOT_DIR}/../Asio" ]]; then ASIO_DIR="${ROOT_DIR}/../Asio"; fi

if [[ ! -d "$TINYXML2_DIR"  && -d "${ROOT_DIR}/../tinyxml2" ]]; then TINYXML2_DIR="${ROOT_DIR}/../tinyxml2"; fi
if [[ ! -d "$TINYXML2_DIR"  && -d "${ROOT_DIR}/../TinyXML2" ]]; then TINYXML2_DIR="${ROOT_DIR}/../TinyXML2"; fi

require_dir "${FOONATHAN_DIR}"
require_dir "${FASTCDR_DIR}"
require_dir "${FASTDDS_DIR}"
require_dir "${ASIO_DIR}"
require_dir "${TINYXML2_DIR}"

ASIO_INCLUDE_SRC="${ASIO_DIR}/asio/include"
if [[ ! -f "${ASIO_INCLUDE_SRC}/asio.hpp" ]]; then
  die "Could not find asio.hpp at expected path: ${ASIO_INCLUDE_SRC}/asio.hpp"
fi

log "Deps:"
log "  FOONATHAN_DIR=${FOONATHAN_DIR}"
log "  FASTCDR_DIR=${FASTCDR_DIR}"
log "  FASTDDS_DIR=${FASTDDS_DIR}"
log "  ASIO_DIR=${ASIO_DIR}"
log "  ASIO_INCLUDE_SRC=${ASIO_INCLUDE_SRC}"
log "  TINYXML2_DIR=${TINYXML2_DIR}"

# -------------------------
# Common cmake args
# -------------------------
COMMON_CMAKE_ARGS=(
  "-DCMAKE_TOOLCHAIN_FILE=${TOOLCHAIN_FILE}"
  "-DCMAKE_INSTALL_PREFIX=${QNX_STAGE}"
  "-DCMAKE_BUILD_TYPE=${BUILD_TYPE}"
  "-DBUILD_SHARED_LIBS=${BUILD_SHARED_LIBS}"
  "-DCMAKE_POSITION_INDEPENDENT_CODE=ON"
  "-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY"
)

build_and_install() {
  local name="$1"
  local src_dir="$2"
  local build_dir="$3"
  shift 3
  local extra_args=("$@")

  log "Configuring ${name}"
  cmake -S "${src_dir}" -B "${build_dir}" \
    "${COMMON_CMAKE_ARGS[@]}" \
    "${extra_args[@]}"

  log "Building ${name}"
  cmake --build "${build_dir}" -j "${JOBS}"

  log "Installing ${name} -> ${QNX_STAGE}"
  cmake --build "${build_dir}" --target install -j "${JOBS}"
}

# -------------------------
# Build directories
# -------------------------
BUILD_ROOT="${ROOT_DIR}/build-qnx-deps"
mkdir -p "${BUILD_ROOT}"

# -------------------------
# Stage standalone Asio headers (header-only)
# -------------------------
log "Staging standalone Asio headers into ${QNX_STAGE}/include"
mkdir -p "${QNX_STAGE}/include"
rsync -a "${ASIO_INCLUDE_SRC}/" "${QNX_STAGE}/include/"

# 1) foonathan_memory (disable tests/examples)
build_and_install "foonathan_memory" "${FOONATHAN_DIR}" "${BUILD_ROOT}/foonathan" \
  "-DFOONATHAN_MEMORY_BUILD_EXAMPLES=OFF" \
  "-DFOONATHAN_MEMORY_BUILD_TESTS=OFF"

# 2) Fast-CDR (disable tests)
build_and_install "Fast-CDR" "${FASTCDR_DIR}" "${BUILD_ROOT}/fastcdr" \
  "-DCMAKE_PREFIX_PATH=${QNX_STAGE}" \
  "-DBUILD_TESTING=OFF"

# 2.5) TinyXML2 (disable tests)
build_and_install "TinyXML2" "${TINYXML2_DIR}" "${BUILD_ROOT}/tinyxml2" \
  "-DBUILD_TESTING=OFF"

# 3) Fast-DDS (disable tests) + point it at staged Asio headers
build_and_install "Fast-DDS" "${FASTDDS_DIR}" "${BUILD_ROOT}/fastdds" \
  "-DCMAKE_PREFIX_PATH=${QNX_STAGE}" \
  "-DASIO_INCLUDE_DIR=${QNX_STAGE}/include" \
  "-DTHIRDPARTY=OFF" \
  "-DBUILD_TESTING=OFF" \
  "-DBUILD_TOOLS=OFF"

# -------------------------
# Improved sanity check (find configs regardless of install location)
# -------------------------
log "Sanity check: installed CMake package configs under ${QNX_STAGE}"
find "${QNX_STAGE}" -maxdepth 6 -name "*-config.cmake" 2>/dev/null | egrep -i "fastdds|fastcdr|foonathan|tinyxml2" || true

log "Sanity check: key libs under ${QNX_STAGE}/lib"
ls -1 "${QNX_STAGE}/lib" 2>/dev/null | egrep -i "fastdds|fastcdr|foonathan|tinyxml2" || true

log "Done."
