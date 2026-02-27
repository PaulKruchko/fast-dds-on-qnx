#!/usr/bin/env python3
import argparse
import csv
import re
from typing import List, Tuple, Optional
import matplotlib.pyplot as plt


def _norm(s: str) -> str:
    s = s.strip().lower()
    s = re.sub(r"\s+", " ", s)
    return s


def _first(fieldnames, candidates) -> Optional[str]:
    m = {_norm(h): h for h in fieldnames}
    for c in candidates:
        k = _norm(c)
        if k in m:
            return m[k]
    return None


def _to_float(v) -> Optional[float]:
    try:
        s = str(v).strip()
        if not s:
            return None
        return float(s)
    except Exception:
        return None


def _to_int(v) -> Optional[int]:
    try:
        s = str(v).strip()
        if not s:
            return None
        return int(float(s))
    except Exception:
        return None


def moving_average(xs: List[float], win: int) -> List[float]:
    if win <= 1 or win > len(xs):
        return xs[:]
    out = []
    s = 0.0
    for i, x in enumerate(xs):
        s += x
        if i >= win:
            s -= xs[i - win]
        if i >= win - 1:
            out.append(s / win)
        else:
            out.append(s / (i + 1))
    return out


def load_latency_series(path: str, keep_timeouts: bool) -> Tuple[List[int], List[float], str]:
    with open(path, "r", newline="") as f:
        r = csv.DictReader(f)
        if not r.fieldnames:
            raise RuntimeError(f"{path}: missing header")
        fields = r.fieldnames

        # New verbose format
        h_iter = _first(fields, ["iteration number"])
        h_rtt = _first(fields, ["round trip time [ms]"])
        h_result = _first(fields, ["result"])
        is_new = (h_iter is not None and h_rtt is not None)

        # Old legacy format
        h_iter_old = _first(fields, ["iter", "iteration", "i"])
        h_rtt_ns = _first(fields, ["rtt_ns"])
        is_old = (h_iter_old is not None and h_rtt_ns is not None)

        if not (is_new or is_old):
            raise RuntimeError(f"{path}: unsupported CSV header: {fields}")

        xs: List[int] = []
        ys: List[float] = []

        for row in r:
            if is_new:
                if not keep_timeouts and h_result:
                    res = (row.get(h_result, "") or "").strip().lower()
                    if res and res != "ok":
                        continue
                it = _to_int(row.get(h_iter))
                rtt = _to_float(row.get(h_rtt))
                if it is None or rtt is None:
                    continue
                if not keep_timeouts and rtt <= 0:
                    continue
                xs.append(it)
                ys.append(rtt)
            else:
                it = _to_int(row.get(h_iter_old))
                rtt_ns = _to_float(row.get(h_rtt_ns))
                if it is None or rtt_ns is None:
                    continue
                if not keep_timeouts and rtt_ns <= 0:
                    continue
                xs.append(it)
                ys.append(rtt_ns / 1e6)

        label = path.split("/")[-1]
        return xs, ys, label


def main():
    ap = argparse.ArgumentParser(description="Plot RTT latency over time (ms).")
    ap.add_argument("csv", help="CSV file from sender (new verbose ms or old ns).")
    ap.add_argument("--keep-timeouts", action="store_true", help="Include non-ok rows / rtt<=0 rows.")
    ap.add_argument("--ma", type=int, default=0, help="Moving average window (samples). 0 disables.")
    ap.add_argument("--out", help="Save plot to file (png/pdf). If omitted, shows window.")
    args = ap.parse_args()

    xs, ys, label = load_latency_series(args.csv, keep_timeouts=args.keep_timeouts)

    if not xs:
        raise SystemExit("No samples to plot (check filters / file).")

    yplot = moving_average(ys, args.ma) if args.ma and args.ma > 1 else ys

    plt.figure()
    plt.plot(xs, yplot)
    plt.xlabel("iteration number")
    plt.ylabel("round trip time [ms]")
    plt.title(f"RTT over time: {label}" + (f" (MA={args.ma})" if args.ma and args.ma > 1 else ""))
    plt.grid(True)

    if args.out:
        plt.savefig(args.out, bbox_inches="tight")
        print(f"Wrote: {args.out}")
    else:
        plt.show()


if __name__ == "__main__":
    main()
    