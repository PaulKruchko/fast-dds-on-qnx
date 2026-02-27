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


def load_cpu_pct_series(path: str, keep_timeouts: bool) -> Tuple[List[int], List[float], str]:
    with open(path, "r", newline="") as f:
        r = csv.DictReader(f)
        if not r.fieldnames:
            raise RuntimeError(f"{path}: missing header")
        fields = r.fieldnames

        h_iter = _first(fields, ["iteration number"])
        h_rtt = _first(fields, ["round trip time [ms]"])
        h_cpu = _first(fields, ["process cpu time [ms]"])
        h_result = _first(fields, ["result"])

        is_new = (h_iter is not None and h_rtt is not None and h_cpu is not None)

        if not is_new:
            raise RuntimeError(
                f"{path}: CPU % plot requires new verbose CSV columns:\n"
                f"  'iteration number', 'round trip time [ms]', 'process cpu time [ms]'\n"
                f"Found: {fields}"
            )

        xs: List[int] = []
        ys: List[float] = []

        for row in r:
            if not keep_timeouts and h_result:
                res = (row.get(h_result, "") or "").strip().lower()
                if res and res != "ok":
                    continue

            it = _to_int(row.get(h_iter))
            rtt = _to_float(row.get(h_rtt))
            cpu = _to_float(row.get(h_cpu))

            if it is None or rtt is None or cpu is None:
                continue
            if rtt <= 0:
                continue

            cpu_pct = 100.0 * (cpu / rtt)
            xs.append(it)
            ys.append(cpu_pct)

        label = path.split("/")[-1]
        return xs, ys, label


def main():
    ap = argparse.ArgumentParser(description="Plot estimated CPU utilization (%) over time.")
    ap.add_argument("csv", help="CSV file from sender (new verbose ms format).")
    ap.add_argument("--keep-timeouts", action="store_true", help="Include non-ok rows.")
    ap.add_argument("--ma", type=int, default=0, help="Moving average window (samples). 0 disables.")
    ap.add_argument("--out", help="Save plot to file (png/pdf). If omitted, shows window.")
    args = ap.parse_args()

    xs, ys, label = load_cpu_pct_series(args.csv, keep_timeouts=args.keep_timeouts)
    if not xs:
        raise SystemExit("No samples to plot (check filters / file).")

    yplot = moving_average(ys, args.ma) if args.ma and args.ma > 1 else ys

    plt.figure()
    plt.plot(xs, yplot)
    plt.xlabel("iteration number")
    plt.ylabel("process cpu utilization estimate [%] (cpu_ms / rtt_ms)")
    plt.title(f"CPU % over time: {label}" + (f" (MA={args.ma})" if args.ma and args.ma > 1 else ""))
    plt.grid(True)

    if args.out:
        plt.savefig(args.out, bbox_inches="tight")
        print(f"Wrote: {args.out}")
    else:
        plt.show()


if __name__ == "__main__":
    main()
    