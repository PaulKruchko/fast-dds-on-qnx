#!/usr/bin/env python3
import argparse
import csv
import math
import re
from dataclasses import dataclass
from typing import List, Optional, Tuple, Dict, Any


def _norm(s: str) -> str:
    s = s.strip().lower()
    s = re.sub(r"\s+", " ", s)
    return s


def _first_present(fieldnames: List[str], candidates: List[str]) -> Optional[str]:
    norm_map = {_norm(h): h for h in fieldnames}
    for c in candidates:
        k = _norm(c)
        if k in norm_map:
            return norm_map[k]
    return None


def _to_float(v: Any) -> Optional[float]:
    try:
        if v is None:
            return None
        s = str(v).strip()
        if s == "":
            return None
        return float(s)
    except Exception:
        return None


def _to_int(v: Any) -> Optional[int]:
    try:
        if v is None:
            return None
        s = str(v).strip()
        if s == "":
            return None
        # handle values that look like floats
        return int(float(s))
    except Exception:
        return None


@dataclass
class Stats:
    name: str
    n: int
    rtt_ms: List[float]
    oneway_ms_est: List[float]
    wall_ms_total: float
    cpu_ms_total: float
    cpu_pct_est: Optional[float]

    def percentile(self, values: List[float], p: float) -> Optional[float]:
        if not values:
            return None
        if p <= 0:
            return float(min(values))
        if p >= 100:
            return float(max(values))
        xs = sorted(values)
        k = (len(xs) - 1) * (p / 100.0)
        f = math.floor(k)
        c = math.ceil(k)
        if f == c:
            return float(xs[int(k)])
        d0 = xs[f] * (c - k)
        d1 = xs[c] * (k - f)
        return float(d0 + d1)

    def mean(self, values: List[float]) -> Optional[float]:
        if not values:
            return None
        return float(sum(values)) / float(len(values))

    def median(self, values: List[float]) -> Optional[float]:
        return self.percentile(values, 50.0)

    def effective_rate_hz(self) -> Optional[float]:
        if self.n <= 0 or self.wall_ms_total <= 0:
            return None
        return self.n / (self.wall_ms_total / 1000.0)

    def summary_rows(self) -> List[Tuple[str, str]]:
        r = self.rtt_ms
        o = self.oneway_ms_est

        def fmt(x: Optional[float]) -> str:
            return "n/a" if x is None else f"{x:,.6f}"

        def fmt_i(x: Optional[float]) -> str:
            return "n/a" if x is None else f"{x:,.0f}"

        rows: List[Tuple[str, str]] = []
        rows.append(("samples", f"{self.n:,}"))
        rows.append(("wall_ms_total", fmt(self.wall_ms_total)))
        rows.append(("cpu_ms_total", fmt(self.cpu_ms_total)))

        rows.append(("cpu_pct_est", "n/a" if self.cpu_pct_est is None else f"{self.cpu_pct_est:.3f}"))
        rate = self.effective_rate_hz()
        rows.append(("rate_hz", "n/a" if rate is None else f"{rate:.3f}"))

        rows.append(("rtt_min_ms", fmt(self.percentile(r, 0))))
        rows.append(("rtt_mean_ms", fmt(self.mean(r))))
        rows.append(("rtt_median_ms", fmt(self.median(r))))
        rows.append(("rtt_p95_ms", fmt(self.percentile(r, 95))))
        rows.append(("rtt_p99_ms", fmt(self.percentile(r, 99))))
        rows.append(("rtt_max_ms", fmt(self.percentile(r, 100))))

        # convenience conversions
        rows.append(("rtt_mean_us", fmt_i(None if not r else (self.mean(r) * 1000.0))))
        rows.append(("rtt_p95_us", fmt_i(None if not r else (self.percentile(r, 95) * 1000.0))))
        rows.append(("rtt_p99_us", fmt_i(None if not r else (self.percentile(r, 99) * 1000.0))))

        rows.append(("oneway_mean_ms_est", fmt(self.mean(o))))
        rows.append(("oneway_median_ms_est", fmt(self.median(o))))

        return rows

    def summary_map_numeric(self) -> Dict[str, Any]:
        r = self.rtt_ms
        o = self.oneway_ms_est
        return {
            "samples": self.n,
            "wall_ms_total": self.wall_ms_total,
            "cpu_ms_total": self.cpu_ms_total,
            "cpu_pct_est": self.cpu_pct_est,
            "rate_hz": self.effective_rate_hz(),
            "rtt_min_ms": self.percentile(r, 0),
            "rtt_mean_ms": self.mean(r),
            "rtt_median_ms": self.median(r),
            "rtt_p95_ms": self.percentile(r, 95),
            "rtt_p99_ms": self.percentile(r, 99),
            "rtt_max_ms": self.percentile(r, 100),
            "rtt_mean_us": None if not r else (self.mean(r) * 1000.0),
            "rtt_p95_us": None if not r else (self.percentile(r, 95) * 1000.0),
            "rtt_p99_us": None if not r else (self.percentile(r, 99) * 1000.0),
            "oneway_mean_ms_est": self.mean(o),
            "oneway_median_ms_est": self.median(o),
        }


def read_csv(path: str, name: Optional[str], skip: int = 0, drop_timeouts: bool = True) -> Stats:
    """
    Supports TWO formats:

    New verbose ms format (preferred):
      backend,role,iteration number,counter,request time send [ms],reply time receive [ms],
      round trip time [ms],process cpu time [ms],result,text

    Old ns format (legacy):
      iter,counter,rtt_ns,oneway_ns_est,wall_ns,cpu_ns,cpu_pct
    """
    rtt_ms: List[float] = []
    oneway_ms: List[float] = []

    cpu_ms_sum: float = 0.0
    wall_ms_total: float = 0.0

    # For deriving wall time when only req/rep timestamps exist
    min_req_ms: Optional[float] = None
    max_rep_ms: Optional[float] = None

    # For legacy: prefer explicit wall/cpu maxima if available
    wall_ms_last: float = 0.0

    n_rows = 0

    with open(path, "r", newline="") as f:
        reader = csv.DictReader(f)
        if reader.fieldnames is None:
            raise RuntimeError(f"{path}: missing header row")

        fields = reader.fieldnames

        # New verbose headers (ms)
        h_iter = _first_present(fields, ["iteration number"])
        h_counter = _first_present(fields, ["counter"])
        h_req_ms = _first_present(fields, ["request time send [ms]"])
        h_rep_ms = _first_present(fields, ["reply time receive [ms]"])
        h_rtt_ms = _first_present(fields, ["round trip time [ms]"])
        h_cpu_ms = _first_present(fields, ["process cpu time [ms]"])
        h_result = _first_present(fields, ["result"])
        h_backend = _first_present(fields, ["backend"])  # optional for series output
        h_text = _first_present(fields, ["text"])        # optional for series output

        is_new = (h_iter is not None and h_counter is not None and h_rtt_ms is not None)

        # Legacy headers (ns)
        h_iter_old = _first_present(fields, ["iter"])
        h_counter_old = _first_present(fields, ["counter"])
        h_rtt_ns = _first_present(fields, ["rtt_ns"])
        h_oneway_ns = _first_present(fields, ["oneway_ns_est"])
        h_wall_ns = _first_present(fields, ["wall_ns"])
        h_cpu_ns = _first_present(fields, ["cpu_ns"])
        h_cpu_pct = _first_present(fields, ["cpu_pct"])  # not strictly required anymore

        is_old = (h_iter_old is not None and h_counter_old is not None and h_rtt_ns is not None)

        if not (is_new or is_old):
            raise RuntimeError(
                f"{path}: unsupported CSV header.\n"
                f"Expected either new ms headers including: "
                f"'iteration number', 'counter', 'round trip time [ms]' "
                f"OR old headers including: 'iter', 'counter', 'rtt_ns'.\n"
                f"Found: {fields}"
            )

        for row in reader:
            n_rows += 1
            if n_rows <= skip:
                continue

            # Drop non-ok rows (new format) unless user requested keep
            if is_new and drop_timeouts and h_result is not None:
                res = (row.get(h_result, "") or "").strip().lower()
                if res and res != "ok":
                    continue

            if is_new:
                v_rtt = _to_float(row.get(h_rtt_ms)) if h_rtt_ms else None
                v_cpu = _to_float(row.get(h_cpu_ms)) if h_cpu_ms else 0.0
                v_req = _to_float(row.get(h_req_ms)) if h_req_ms else None
                v_rep = _to_float(row.get(h_rep_ms)) if h_rep_ms else None

                if v_rtt is None:
                    continue

                if drop_timeouts and v_rtt <= 0:
                    continue

                rtt_ms.append(v_rtt)
                oneway_ms.append(v_rtt / 2.0)

                if v_cpu is not None and v_cpu > 0:
                    cpu_ms_sum += v_cpu

                if v_req is not None:
                    min_req_ms = v_req if (min_req_ms is None or v_req < min_req_ms) else min_req_ms
                if v_rep is not None:
                    max_rep_ms = v_rep if (max_rep_ms is None or v_rep > max_rep_ms) else max_rep_ms

            else:
                v_rtt_ns = _to_float(row.get(h_rtt_ns)) if h_rtt_ns else None
                v_oneway_ns = _to_float(row.get(h_oneway_ns)) if h_oneway_ns else None
                v_wall_ns = _to_float(row.get(h_wall_ns)) if h_wall_ns else None
                v_cpu_ns = _to_float(row.get(h_cpu_ns)) if h_cpu_ns else None

                if v_rtt_ns is None:
                    continue
                if drop_timeouts and v_rtt_ns <= 0:
                    continue

                rtt_ms.append(v_rtt_ns / 1e6)
                if v_oneway_ns is not None:
                    oneway_ms.append(v_oneway_ns / 1e6)
                else:
                    oneway_ms.append((v_rtt_ns / 2.0) / 1e6)

                if v_cpu_ns is not None and v_cpu_ns > 0:
                    # legacy cpu_ns is typically cumulative; keep last max and also sum deltas if desired
                    cpu_ms_sum = max(cpu_ms_sum, v_cpu_ns / 1e6)

                if v_wall_ns is not None and v_wall_ns > 0:
                    wall_ms_last = max(wall_ms_last, v_wall_ns / 1e6)

        # Derive wall time for new format from timestamps if possible
        if is_new:
            if min_req_ms is not None and max_rep_ms is not None and max_rep_ms >= min_req_ms:
                wall_ms_total = max_rep_ms - min_req_ms
            else:
                # fallback: approximate by sum RTTs (not great but better than 0)
                wall_ms_total = sum(rtt_ms)
        else:
            wall_ms_total = wall_ms_last if wall_ms_last > 0 else sum(rtt_ms)

    if name is None:
        name = path

    cpu_pct_est: Optional[float] = None
    if wall_ms_total > 0 and cpu_ms_sum > 0:
        cpu_pct_est = 100.0 * (cpu_ms_sum / wall_ms_total)

    return Stats(
        name=name,
        n=len(rtt_ms),
        rtt_ms=rtt_ms,
        oneway_ms_est=oneway_ms,
        wall_ms_total=wall_ms_total,
        cpu_ms_total=cpu_ms_sum,
        cpu_pct_est=cpu_pct_est,
    )


def print_table(stats_list: List[Stats]) -> None:
    keys = [k for k, _ in stats_list[0].summary_rows()]
    for st in stats_list[1:]:
        for k, _ in st.summary_rows():
            if k not in keys:
                keys.append(k)

    values = []
    for k in keys:
        row = [k]
        for st in stats_list:
            m = dict(st.summary_rows())
            row.append(m.get(k, "n/a"))
        values.append(row)

    col_names = ["metric"] + [st.name for st in stats_list]
    widths = [max(len(col_names[i]), max(len(v[i]) for v in values)) for i in range(len(col_names))]

    def fmt_row(cols):
        return "  ".join(cols[i].ljust(widths[i]) for i in range(len(cols)))

    print(fmt_row(col_names))
    print(fmt_row(["-" * w for w in widths]))
    for row in values:
        print(fmt_row(row))


def write_long_csv(path: str, stats_list: List[Stats]) -> None:
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["dataset", "metric", "value"])
        for st in stats_list:
            m = st.summary_map_numeric()
            for k, v in m.items():
                w.writerow([st.name, k, "" if v is None else v])


def write_wide_csv(path: str, stats_list: List[Stats]) -> None:
    metrics: List[str] = []
    for st in stats_list:
        for k in st.summary_map_numeric().keys():
            if k not in metrics:
                metrics.append(k)

    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["dataset"] + metrics)
        for st in stats_list:
            m = st.summary_map_numeric()
            row = [st.name] + [("" if m.get(k) is None else m.get(k)) for k in metrics]
            w.writerow(row)


def write_series_csv(path: str, csv_paths: List[str], names: List[str], skip: int, drop_timeouts: bool) -> None:
    """
    Merge per-sample data into a single long-form file for plotting.

    Output columns (ms, verbose-friendly):
      dataset,backend,role,iteration number,counter,request time send [ms],reply time receive [ms],
      round trip time [ms],process cpu time [ms],result,text
    """
    with open(path, "w", newline="") as outf:
        w = csv.writer(outf)
        w.writerow([
            "dataset",
            "backend",
            "role",
            "iteration number",
            "counter",
            "request time send [ms]",
            "reply time receive [ms]",
            "round trip time [ms]",
            "process cpu time [ms]",
            "result",
            "text",
        ])

        for i, in_path in enumerate(csv_paths):
            dataset = names[i] if names else in_path

            with open(in_path, "r", newline="") as f:
                reader = csv.DictReader(f)
                if reader.fieldnames is None:
                    raise RuntimeError(f"{in_path}: missing header row")

                fields = reader.fieldnames

                # New format selectors
                h_iter = _first_present(fields, ["iteration number"])
                h_counter = _first_present(fields, ["counter"])
                h_req_ms = _first_present(fields, ["request time send [ms]"])
                h_rep_ms = _first_present(fields, ["reply time receive [ms]"])
                h_rtt_ms = _first_present(fields, ["round trip time [ms]"])
                h_cpu_ms = _first_present(fields, ["process cpu time [ms]"])
                h_result = _first_present(fields, ["result"])
                h_backend = _first_present(fields, ["backend"])
                h_role = _first_present(fields, ["role"])
                h_text = _first_present(fields, ["text"])

                is_new = (h_iter is not None and h_counter is not None and h_rtt_ms is not None)

                # Old format selectors
                h_iter_old = _first_present(fields, ["iter"])
                h_counter_old = _first_present(fields, ["counter"])
                h_rtt_ns = _first_present(fields, ["rtt_ns"])
                h_wall_ns = _first_present(fields, ["wall_ns"])  # optional
                h_cpu_ns = _first_present(fields, ["cpu_ns"])    # optional

                is_old = (h_iter_old is not None and h_counter_old is not None and h_rtt_ns is not None)

                if not (is_new or is_old):
                    raise RuntimeError(f"{in_path}: unsupported CSV header: {fields}")

                n_rows = 0
                for row in reader:
                    n_rows += 1
                    if n_rows <= skip:
                        continue

                    if is_new:
                        res = (row.get(h_result, "ok") or "ok").strip().lower() if h_result else "ok"
                        if drop_timeouts and res != "ok":
                            continue

                        rtt = _to_float(row.get(h_rtt_ms))
                        if rtt is None:
                            continue
                        if drop_timeouts and rtt <= 0:
                            continue

                        w.writerow([
                            dataset,
                            row.get(h_backend, "") if h_backend else "",
                            row.get(h_role, "") if h_role else "",
                            row.get(h_iter, ""),
                            row.get(h_counter, ""),
                            row.get(h_req_ms, "") if h_req_ms else "",
                            row.get(h_rep_ms, "") if h_rep_ms else "",
                            row.get(h_rtt_ms, ""),
                            row.get(h_cpu_ms, "") if h_cpu_ms else "",
                            row.get(h_result, "") if h_result else "",
                            row.get(h_text, "") if h_text else "",
                        ])
                    else:
                        # Convert old ns -> ms where possible; not all fields exist.
                        rtt_ns = _to_float(row.get(h_rtt_ns))
                        if rtt_ns is None:
                            continue
                        if drop_timeouts and rtt_ns <= 0:
                            continue

                        rtt_ms = rtt_ns / 1e6
                        cpu_ms = ""
                        if h_cpu_ns:
                            cpu_ns = _to_float(row.get(h_cpu_ns))
                            if cpu_ns is not None:
                                cpu_ms = cpu_ns / 1e6

                        w.writerow([
                            dataset,
                            "",                 # backend unknown in old
                            "sender",           # assumed
                            row.get(h_iter_old, ""),
                            row.get(h_counter_old, ""),
                            "",                 # req time not present
                            "",                 # rep time not present
                            f"{rtt_ms}",
                            f"{cpu_ms}" if cpu_ms != "" else "",
                            "ok",               # old has no result
                            "",
                        ])


def main():
    ap = argparse.ArgumentParser(
        description="Compare IPC benchmark CSVs (Fast DDS vs PPS, polling vs waitset, etc.)."
    )
    ap.add_argument("csv", nargs="+", help="CSV file(s) produced by sender (redirect stdout to a file).")
    ap.add_argument("--name", action="append", help="Optional display name per CSV (repeat to match csv args).")
    ap.add_argument("--skip", type=int, default=0, help="Skip first N data rows (after header).")
    ap.add_argument("--keep-timeouts", action="store_true",
                    help="Keep timeout/error rows (new format uses result!=ok; old format uses rtt<=0).")

    ap.add_argument("--out-long", help="Write long-form combined CSV: dataset,metric,value")
    ap.add_argument("--out-wide", help="Write wide-form combined CSV: one row per dataset")
    ap.add_argument("--out-series", help="Write plot-ready per-sample merged CSV (ms, verbose columns)")

    args = ap.parse_args()

    names = args.name or []
    if names and len(names) != len(args.csv):
        raise SystemExit("--name must be repeated the same number of times as CSV files (or not used).")

    drop_timeouts = not args.keep_timeouts

    stats_list: List[Stats] = []
    for i, path in enumerate(args.csv):
        nm = names[i] if names else None
        st = read_csv(path, nm, skip=args.skip, drop_timeouts=drop_timeouts)
        stats_list.append(st)

    if not stats_list:
        raise SystemExit("No input CSVs")

    print_table(stats_list)

    if args.out_long:
        write_long_csv(args.out_long, stats_list)
        print(f"\nWrote long-form CSV: {args.out_long}")

    if args.out_wide:
        write_wide_csv(args.out_wide, stats_list)
        print(f"Wrote wide-form CSV: {args.out_wide}")

    if args.out_series:
        write_series_csv(args.out_series, args.csv, names, args.skip, drop_timeouts)
        print(f"Wrote plot-ready series CSV: {args.out_series}")


if __name__ == "__main__":
    main()
    