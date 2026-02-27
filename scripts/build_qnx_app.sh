#!/usr/bin/env bash
# scripts/build_qnx_app.sh
#
# Configure + build ipcbench for QNX using repo-local qnx_stage deps.
# Auto-loads the most recent generated/*/idl_gen.env (if present) and passes:
#   -DIDL_FILE=...
#   -DIPCBENCH_GENERATED_IDL_DIR=...
#   -DIPCBENCH_GEN_BASENAME=...
#
# Usage:
#   source ~/qnx710/qnxsdp-env.sh
#   ./scripts/build_qnx_app.sh
#
# Overrides:
#   BUILD_DIR=build-qnx-debug BUILD_TYPE=Debug ./scripts/build_qnx_app.sh
#   IPC_USE_FASTDDS=ON IPC_USE_PPS=OFF ./scripts/build_qnx_app.sh
#   FD_SHIM_USE_WAITSET=OFF ./scripts/build_qnx_app.sh
#   IDL_FILE=src/idl/Hello.idl ./scripts/build_qnx_app.sh
#   IDL_ENV_FILE=generated/Hello/idl_gen.env ./scripts/build_qnx_app.sh
#   QNX_STAGE_OVERRIDE=/abs/path ./scripts/build_qnx_app.sh
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLCHAIN_FILE="${ROOT_DIR}/qnx.toolchain.cmake"

: "${BUILD_DIR:=build-qnx}"
: "${BUILD_TYPE:=Release}"

: "${IPC_USE_FASTDDS:=ON}"
: "${IPC_USE_PPS:=OFF}"
: "${FD_SHIM_USE_WAITSET:=ON}"

# Default stage is repo-local; allow override for this invocation
QNX_STAGE_DEFAULT="${ROOT_DIR}/qnx_stage"
: "${QNX_STAGE_OVERRIDE:=${QNX_STAGE_DEFAULT}}"
QNX_STAGE="${QNX_STAGE_OVERRIDE}"

# Package config locations in our stage prefix
FASTDDS_DIR="${QNX_STAGE}/share/fastdds/cmake"
FASTCDR_DIR="${QNX_STAGE}/lib/cmake/fastcdr"
FOONATHAN_DIR="${QNX_STAGE}/lib/foonathan_memory/cmake"

log() { printf "\n\033[1;34m==> %s\033[0m\n" "$*"; }
die() { printf "\n\033[1;31mERROR:\033[0m %s\n" "$*" >&2; exit 1; }

[[ -f "${TOOLCHAIN_FILE}" ]] || die "Missing toolchain file: ${TOOLCHAIN_FILE}"
[[ -d "${QNX_STAGE}" ]] || die "Missing stage prefix: ${QNX_STAGE} (run scripts/build_qnx_deps.sh first)"
[[ -f "${FASTDDS_DIR}/fastdds-config.cmake" ]] || die "Missing fastdds CMake config: ${FASTDDS_DIR}/fastdds-config.cmake"
[[ -f "${FASTCDR_DIR}/fastcdr-config.cmake" ]] || die "Missing fastcdr CMake config: ${FASTCDR_DIR}/fastcdr-config.cmake"
[[ -f "${FOONATHAN_DIR}/foonathan_memory-config.cmake" ]] || die "Missing foonathan_memory CMake config: ${FOONATHAN_DIR}/foonathan_memory-config.cmake"

# -------------------------
# Load IDL generation env (optional)
# -------------------------
if [[ -n "${IDL_ENV_FILE:-}" ]]; then
  ENV_CANDIDATE="${IDL_ENV_FILE}"
  [[ "${ENV_CANDIDATE}" != /* ]] && ENV_CANDIDATE="${ROOT_DIR}/${ENV_CANDIDATE}"
else
  ENV_CANDIDATE="$(ls -t "${ROOT_DIR}/generated"/*/idl_gen.env 2>/dev/null | head -n 1 || true)"
fi

if [[ -n "${ENV_CANDIDATE}" && -f "${ENV_CANDIDATE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_CANDIDATE}"
  : "${IDL_FILE:=${IPCBENCH_IDL_FILE}}"
  : "${IPCBENCH_GENERATED_IDL_DIR:=${IPCBENCH_GENERATED_IDL_DIR}}"
  : "${IPCBENCH_GEN_BASENAME:=${IPCBENCH_GEN_BASENAME}}"
  log "Loaded IDL settings from: ${ENV_CANDIDATE}"
else
  log "No idl_gen.env found; using CMake defaults"
fi

# Normalize relative IDL_FILE to repo-root-relative
if [[ -n "${IDL_FILE:-}" && "${IDL_FILE}" != /* ]]; then
  IDL_FILE="${ROOT_DIR}/${IDL_FILE}"
fi

# Normalize generated dir if relative
if [[ -n "${IPCBENCH_GENERATED_IDL_DIR:-}" && "${IPCBENCH_GENERATED_IDL_DIR}" != /* ]]; then
  IPCBENCH_GENERATED_IDL_DIR="${ROOT_DIR}/${IPCBENCH_GENERATED_IDL_DIR}"
fi

log "Configuring QNX app build"
log "  BUILD_DIR=${BUILD_DIR}"
log "  QNX_STAGE=${QNX_STAGE}"
log "  fastdds_DIR=${FASTDDS_DIR}"
log "  fastcdr_DIR=${FASTCDR_DIR}"
log "  foonathan_memory_DIR=${FOONATHAN_DIR}"
log "  IPC_USE_FASTDDS=${IPC_USE_FASTDDS}  IPC_USE_PPS=${IPC_USE_PPS}  FD_SHIM_USE_WAITSET=${FD_SHIM_USE_WAITSET}"
[[ -n "${IDL_FILE:-}" ]] && log "  IDL_FILE=${IDL_FILE}"
[[ -n "${IPCBENCH_GENERATED_IDL_DIR:-}" ]] && log "  IPCBENCH_GENERATED_IDL_DIR=${IPCBENCH_GENERATED_IDL_DIR}"
[[ -n "${IPCBENCH_GEN_BASENAME:-}" ]] && log "  IPCBENCH_GEN_BASENAME=${IPCBENCH_GEN_BASENAME}"

cmake -S "${ROOT_DIR}" -B "${ROOT_DIR}/${BUILD_DIR}" \
  -DCMAKE_TOOLCHAIN_FILE="${TOOLCHAIN_FILE}" \
  -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
  -DCMAKE_PREFIX_PATH="${QNX_STAGE}" \
  -Dfastdds_DIR="${FASTDDS_DIR}" \
  -Dfastcdr_DIR="${FASTCDR_DIR}" \
  -Dfoonathan_memory_DIR="${FOONATHAN_DIR}" \
  -DIPC_USE_FASTDDS="${IPC_USE_FASTDDS}" \
  -DIPC_USE_PPS="${IPC_USE_PPS}" \
  -DFD_SHIM_USE_WAITSET="${FD_SHIM_USE_WAITSET}" \
  ${IDL_FILE:+-DIDL_FILE="${IDL_FILE}"} \
  ${IPCBENCH_GENERATED_IDL_DIR:+-DIPCBENCH_GENERATED_IDL_DIR="${IPCBENCH_GENERATED_IDL_DIR}"} \
  ${IPCBENCH_GEN_BASENAME:+-DIPCBENCH_GEN_BASENAME="${IPCBENCH_GEN_BASENAME}"}

log "Building"
cmake --build "${ROOT_DIR}/${BUILD_DIR}" -j "$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"

log "Done."
echo "Built outputs are in: ${ROOT_DIR}/${BUILD_DIR}"
