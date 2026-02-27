#!/bin/sh
# Minimal QNX runner (works on stripped images: no printf/nl/date/head).
set -eu

MODE="${1:-both}"

TARGET_DIR="${TARGET_DIR:-$(pwd)}"
OUTDIR="${OUTDIR:-$TARGET_DIR/out}"
SENDER_NAME="${SENDER_NAME:-sender}"
RECEIVER_NAME="${RECEIVER_NAME:-receiver}"

RECEIVER_BG="${RECEIVER_BG:-1}"
KILL_RECEIVER="${KILL_RECEIVER:-1}"
CAPTURE_CSV="${CAPTURE_CSV:-1}"
IPCBENCH_BACKEND="${IPCBENCH_BACKEND:-fastdds}"

BIN_DIR="$TARGET_DIR/bin"
LIB_DIR="$TARGET_DIR/lib"
ETC_DIR="$TARGET_DIR/etc"
PROFILES="$ETC_DIR/fastdds_profiles.xml"

log() { echo ""; echo "==> $*"; }
die() { echo ""; echo "ERROR: $*" >&2; exit 1; }

[ -d "$BIN_DIR" ] || die "Missing $BIN_DIR (did you deploy to $TARGET_DIR?)"
[ -d "$LIB_DIR" ] || die "Missing $LIB_DIR (did you deploy libs?)"
[ -x "$BIN_DIR/sender" ] || die "Missing executable: $BIN_DIR/sender"
[ -x "$BIN_DIR/receiver" ] || die "Missing executable: $BIN_DIR/receiver"

mkdir -p "$OUTDIR"

LD_LIBRARY_PATH="$LIB_DIR:$BIN_DIR:/lib:/usr/lib:${LD_LIBRARY_PATH:-}"
export LD_LIBRARY_PATH

if [ -f "$PROFILES" ]; then
  FASTDDS_DEFAULT_PROFILES_FILE="$PROFILES"
  export FASTDDS_DEFAULT_PROFILES_FILE
fi

IPCBENCH_OUTDIR="$OUTDIR"
export IPCBENCH_OUTDIR

RECEIVER_PID=""

cleanup() {
  if [ "$KILL_RECEIVER" = "1" ] && [ -n "$RECEIVER_PID" ]; then
    log "Stopping receiver (pid=$RECEIVER_PID)"
    kill "$RECEIVER_PID" 2>/dev/null || true
    # wait may not exist on some shells; ignore errors
    wait "$RECEIVER_PID" 2>/dev/null || true
  fi
}
trap cleanup 0 2 15

run_receiver_fg() {
  log "Starting receiver (foreground)"
  cd "$BIN_DIR"
  exec ./receiver "$RECEIVER_NAME"
}

run_receiver_bg() {
  log "Starting receiver (background)"
  ( cd "$BIN_DIR" && ./receiver "$RECEIVER_NAME" ) &
  RECEIVER_PID="$!"
  # sleep usually exists; if not, remove this line
  sleep 1 2>/dev/null || true
}

run_sender_fg() {
  log "Starting sender (foreground)"
  cd "$BIN_DIR"
  if [ "$CAPTURE_CSV" = "1" ]; then
    OUTFILE="$OUTDIR/${IPCBENCH_BACKEND}_sender.csv"
    log "Capturing sender stdout -> $OUTFILE"
    exec ./sender "$SENDER_NAME" > "$OUTFILE"
  else
    exec ./sender "$SENDER_NAME"
  fi
}

log "Run settings"
log "  MODE=$MODE"
log "  TARGET_DIR=$TARGET_DIR"
log "  OUTDIR=$OUTDIR"
log "  LD_LIBRARY_PATH=$LD_LIBRARY_PATH"

case "$MODE" in
  receiver) run_receiver_fg ;;
  sender)   run_sender_fg ;;
  both)
    if [ "$RECEIVER_BG" = "1" ]; then
      run_receiver_bg
    else
      run_receiver_fg
    fi

    log "Starting sender (foreground)"
    cd "$BIN_DIR"
    if [ "$CAPTURE_CSV" = "1" ]; then
      OUTFILE="$OUTDIR/${IPCBENCH_BACKEND}_sender.csv"
      log "Capturing sender stdout -> $OUTFILE"
      ./sender "$SENDER_NAME" > "$OUTFILE"
    else
      ./sender "$SENDER_NAME"
    fi

    log "Sender finished."
    sleep 1 2>/dev/null || true
    ;;
  *) die "Unknown mode: $MODE (use: receiver | sender | both)" ;;
esac

log "Done."
