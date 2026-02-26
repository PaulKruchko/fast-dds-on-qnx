#!/usr/bin/env bash
# scripts/build_linux_deps.sh
#
# Build + install Fast DDS dependencies into a staging prefix for native Linux x86_64.
#
# Usage:
#   ./scripts/build_linux_deps.sh
#
# Optional overrides:
#   LINUX_STAGE=/abs/path/to/linux_stage ./scripts/build_linux_deps.sh
#   FOONATHAN_DIR=~/foonathan_memory FASTCDR_DIR=~/Fast-CDR FASTDDS_DIR=~/Fast-DDS ./scripts/build_linux_deps.sh
#   ASIO_DIR=~/asio ./scripts/build_linux_deps.sh
#   BUILD_TYPE=Debug ./scripts/build_linux_deps.sh
#   BUILD_SHARED_LIBS=OFF ./scripts/build_linux_deps.sh
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${LINUX_STAGE:=${ROOT_DIR}/linux_stage}"
: "${BUILD_TYPE:=Release}"
: "${BUILD_SHARED_LIBS:=ON}"
: "${JOBS:=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"

log() { printf "\n\033[1;34m==> %s\033[0m\n" "$*"; }
die() { printf "\n\033[1;31mERROR:\033[0m %s\n" "$*" >&2; exit 1; }

require_dir() { [[ -d "$1" ]] || die "Missing directory: $1"; }

log "Using staging prefix: ${LINUX_STAGE}"
mkdir -p "${LINUX_STAGE}"

# -------------------------
# Dependency source dirs
# -------------------------
# Allow overrides; otherwise try:
#   1) repo root (./Fast-DDS etc.)
#   2) parent of repo root (../Fast-DDS etc.)  <-- your current layout
: "${FOONATHAN_DIR:=${ROOT_DIR}/foonathan_memory}"
: "${FASTCDR_DIR:=${ROOT_DIR}/Fast-CDR}"
: "${FASTDDS_DIR:=${ROOT_DIR}/Fast-DDS}"
: "${ASIO_DIR:=${ROOT_DIR}/asio}"

if [[ ! -d "$FOONATHAN_DIR" && -d "${ROOT_DIR}/../foonathan_memory" ]]; then
  FOONATHAN_DIR="${ROOT_DIR}/../foonathan_memory"
fi
if [[ ! -d "$FASTCDR_DIR" && -d "${ROOT_DIR}/../Fast-CDR" ]]; then
  FASTCDR_DIR="${ROOT_DIR}/../Fast-CDR"
fi
if [[ ! -d "$FASTDDS_DIR" && -d "${ROOT_DIR}/../Fast-DDS" ]]; then
  FASTDDS_DIR="${ROOT_DIR}/../Fast-DDS"
fi
# Asio repo is commonly ~/asio or alongside other deps
if [[ ! -d "$ASIO_DIR" && -d "${ROOT_DIR}/../asio" ]]; then
  ASIO_DIR="${ROOT_DIR}/../asio"
fi
if [[ ! -d "$ASIO_DIR" && -d "${ROOT_DIR}/../Asio" ]]; then
  ASIO_DIR="${ROOT_DIR}/../Asio"
fi

require_dir "${FOONATHAN_DIR}"
require_dir "${FASTCDR_DIR}"
require_dir "${FASTDDS_DIR}"
require_dir "${ASIO_DIR}"

# Asio headers path inside the repo is typically: <repo>/asio/include/
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

COMMON_CMAKE_ARGS=(
  "-DCMAKE_INSTALL_PREFIX=${LINUX_STAGE}"
  "-DCMAKE_BUILD_TYPE=${BUILD_TYPE}"
  "-DBUILD_SHARED_LIBS=${BUILD_SHARED_LIBS}"
  "-DCMAKE_POSITION_INDEPENDENT_CODE=ON"
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

  log "Installing ${name} -> ${LINUX_STAGE}"
  cmake --build "${build_dir}" --target install -j "${JOBS}"
}

# -------------------------
# Build directories (ignored by git)
# -------------------------
BUILD_ROOT="${ROOT_DIR}/build-linux-deps"
mkdir -p "${BUILD_ROOT}"

# -------------------------
# Install standalone Asio headers into the stage prefix (header-only)
# -------------------------
log "Staging standalone Asio headers into ${LINUX_STAGE}/include"
mkdir -p "${LINUX_STAGE}/include"
rsync -a "${ASIO_INCLUDE_SRC}/" "${LINUX_STAGE}/include/"

# 1) foonathan_memory (disable tests/examples)
build_and_install "foonathan_memory" "${FOONATHAN_DIR}" "${BUILD_ROOT}/foonathan" \
  "-DFOONATHAN_MEMORY_BUILD_EXAMPLES=OFF" \
  "-DFOONATHAN_MEMORY_BUILD_TESTS=OFF" \
  "-DBUILD_TESTING=OFF"

# 2) Fast-CDR (disable tests)
build_and_install "Fast-CDR" "${FASTCDR_DIR}" "${BUILD_ROOT}/fastcdr" \
  "-DCMAKE_PREFIX_PATH=${LINUX_STAGE}" \
  "-DBUILD_TESTING=OFF"

# 3) Fast-DDS (disable tests) + point it at staged Asio headers
build_and_install "Fast-DDS" "${FASTDDS_DIR}" "${BUILD_ROOT}/fastdds" \
  "-DCMAKE_PREFIX_PATH=${LINUX_STAGE}" \
  "-DASIO_INCLUDE_DIR=${LINUX_STAGE}/include" \
  "-DTHIRDPARTY=OFF" \
  "-DBUILD_TESTING=OFF" \
  "-DBUILD_TOOLS=OFF" 

log "Sanity check: installed CMake packages under ${LINUX_STAGE}"
if [[ -d "${LINUX_STAGE}/lib/cmake" ]]; then
  ls -1 "${LINUX_STAGE}/lib/cmake" || true
else
  log "Note: ${LINUX_STAGE}/lib/cmake does not exist (some installs may use lib64)."
  [[ -d "${LINUX_STAGE}/lib64/cmake" ]] && ls -1 "${LINUX_STAGE}/lib64/cmake" || true
fi

log "Done."
echo
echo "Next (build your app):"
echo "  cmake -S ${ROOT_DIR} -B ${ROOT_DIR}/build-linux \\"
echo "    -DCMAKE_PREFIX_PATH=${LINUX_STAGE} \\"
echo "    -DIPC_USE_FASTDDS=ON -DIPC_USE_PPS=OFF -DFD_SHIM_USE_WAITSET=ON"
echo "  cmake --build ${ROOT_DIR}/build-linux -j ${JOBS}"
