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


def load_rtt_ms(path: str, keep_timeouts: bool) -> Tuple[List[float], str]:
    with open(path, "r", newline="") as f:
        r = csv.DictReader(f)
        if not r.fieldnames:
            raise RuntimeError(f"{path}: missing header")
        fields = r.fieldnames

        # New format
        h_rtt = _first(fields, ["round trip time [ms]"])
        h_result = _first(fields, ["result"])
        is_new = (h_rtt is not None)

        # Old format
        h_rtt_ns = _first(fields, ["rtt_ns"])
        is_old = (h_rtt_ns is not None)

        if not (is_new or is_old):
            raise RuntimeError(f"{path}: unsupported CSV header: {fields}")

        vals: List[float] = []
        for row in r:
            if is_new:
                if not keep_timeouts and h_result:
                    res = (row.get(h_result, "") or "").strip().lower()
                    if res and res != "ok":
                        continue
                v = _to_float(row.get(h_rtt))
                if v is None:
                    continue
                if not keep_timeouts and v <= 0:
                    continue
                vals.append(v)
            else:
                vns = _to_float(row.get(h_rtt_ns))
                if vns is None:
                    continue
                if not keep_timeouts and vns <= 0:
                    continue
                vals.append(vns / 1e6)

        label = path.split("/")[-1]
        return vals, label


def compute_cdf(vals: List[float]) -> Tuple[List[float], List[float]]:
    xs = sorted(vals)
    n = len(xs)
    ys = [(i + 1) / n for i in range(n)]
    return xs, ys


def main():
    ap = argparse.ArgumentParser(description="Plot CDF of RTT latency (ms).")
    ap.add_argument("csv", nargs="+", help="One or more CSV files.")
    ap.add_argument("--keep-timeouts", action="store_true", help="Include non-ok rows / rtt<=0.")
    ap.add_argument("--out", help="Save plot to file (png/pdf). If omitted, shows window.")
    args = ap.parse_args()

    plt.figure()
    for path in args.csv:
        vals, label = load_rtt_ms(path, keep_timeouts=args.keep_timeouts)
        if not vals:
            print(f"WARNING: no samples in {path}")
            continue
        xs, ys = compute_cdf(vals)
        plt.plot(xs, ys, label=label)

    plt.xlabel("round trip time [ms]")
    plt.ylabel("fraction of samples ≤ x")
    plt.title("RTT CDF")
    plt.grid(True)
    plt.legend()

    if args.out:
        plt.savefig(args.out, bbox_inches="tight")
        print(f"Wrote: {args.out}")
    else:
        plt.show()


if __name__ == "__main__":
    main()
    