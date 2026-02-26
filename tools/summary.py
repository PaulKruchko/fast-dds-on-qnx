#!/usr/bin/env python3
import argparse
import csv
import math
from dataclasses import dataclass
from typing import List, Optional, Tuple, Dict, Any


@dataclass
class Stats:
    name: str
    n: int
    rtt_ns: List[int]
    oneway_ns: List[int]
    wall_ns_last: int
    cpu_ns_last: int

    def percentile(self, values: List[int], p: float) -> Optional[float]:
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

    def mean(self, values: List[int]) -> Optional[float]:
        if not values:
            return None
        return float(sum(values)) / float(len(values))

    def median(self, values: List[int]) -> Optional[float]:
        return self.percentile(values, 50.0)

    def effective_rate_hz(self) -> Optional[float]:
        if self.n <= 0 or self.wall_ns_last <= 0:
            return None
        return (self.n / (self.wall_ns_last / 1e9))

    def cpu_pct_avg(self) -> Optional[float]:
        if self.wall_ns_last <= 0:
            return None
        return 100.0 * (self.cpu_ns_last / self.wall_ns_last)

    def summary_rows(self) -> List[Tuple[str, str]]:
        r = self.rtt_ns
        o = self.oneway_ns

        def fmt(x: Optional[float]) -> str:
            return "n/a" if x is None else f"{x:,.0f}"

        def fmt_us(x: Optional[float]) -> str:
            return "n/a" if x is None else f"{(x / 1000.0):,.3f}"

        rows: List[Tuple[str, str]] = []
        rows.append(("samples", f"{self.n:,}"))
        rows.append(("wall_ns", f"{self.wall_ns_last:,}"))
        rows.append(("cpu_ns", f"{self.cpu_ns_last:,}"))

        cpu_pct = self.cpu_pct_avg()
        rows.append(("cpu_pct_avg", "n/a" if cpu_pct is None else f"{cpu_pct:.3f}"))

        rate = self.effective_rate_hz()
        rows.append(("rate_hz", "n/a" if rate is None else f"{rate:.3f}"))

        rows.append(("rtt_min_ns", fmt(self.percentile(r, 0))))
        rows.append(("rtt_mean_ns", fmt(self.mean(r))))
        rows.append(("rtt_median_ns", fmt(self.median(r))))
        rows.append(("rtt_p95_ns", fmt(self.percentile(r, 95))))
        rows.append(("rtt_p99_ns", fmt(self.percentile(r, 99))))
        rows.append(("rtt_max_ns", fmt(self.percentile(r, 100))))

        rows.append(("rtt_min_us", fmt_us(self.percentile(r, 0))))
        rows.append(("rtt_mean_us", fmt_us(self.mean(r))))
        rows.append(("rtt_median_us", fmt_us(self.median(r))))
        rows.append(("rtt_p95_us", fmt_us(self.percentile(r, 95))))
        rows.append(("rtt_p99_us", fmt_us(self.percentile(r, 99))))
        rows.append(("rtt_max_us", fmt_us(self.percentile(r, 100))))

        rows.append(("oneway_mean_ns_est", fmt(self.mean(o))))
        rows.append(("oneway_median_ns_est", fmt(self.median(o))))
        rows.append(("oneway_mean_us_est", fmt_us(self.mean(o))))
        rows.append(("oneway_median_us_est", fmt_us(self.median(o))))

        return rows

    def summary_map_numeric(self) -> Dict[str, Any]:
        r = self.rtt_ns
        o = self.oneway_ns
        return {
            "samples": self.n,
            "wall_ns": self.wall_ns_last,
            "cpu_ns": self.cpu_ns_last,
            "cpu_pct_avg": self.cpu_pct_avg(),
            "rate_hz": self.effective_rate_hz(),
            "rtt_min_ns": self.percentile(r, 0),
            "rtt_mean_ns": self.mean(r),
            "rtt_median_ns": self.median(r),
            "rtt_p95_ns": self.percentile(r, 95),
            "rtt_p99_ns": self.percentile(r, 99),
            "rtt_max_ns": self.percentile(r, 100),
            "rtt_min_us": None if not r else min(r) / 1000.0,
            "rtt_mean_us": None if not r else (self.mean(r) / 1000.0),
            "rtt_median_us": None if not r else (self.median(r) / 1000.0),
            "rtt_p95_us": None if not r else (self.percentile(r, 95) / 1000.0),
            "rtt_p99_us": None if not r else (self.percentile(r, 99) / 1000.0),
            "rtt_max_us": None if not r else max(r) / 1000.0,
            "oneway_mean_ns_est": self.mean(o),
            "oneway_median_ns_est": self.median(o),
            "oneway_mean_us_est": None if not o else (self.mean(o) / 1000.0),
            "oneway_median_us_est": None if not o else (self.median(o) / 1000.0),
        }


def read_csv(path: str, name: Optional[str], skip: int = 0, drop_timeouts: bool = True) -> Stats:
    rtt: List[int] = []
    oneway: List[int] = []
    wall_last = 0
    cpu_last = 0
    n_rows = 0

    with open(path, "r", newline="") as f:
        reader = csv.DictReader(f)
        if reader.fieldnames is None:
            raise RuntimeError(f"{path}: missing header row")

        required = {"iter", "counter", "rtt_ns", "oneway_ns_est", "wall_ns", "cpu_ns", "cpu_pct"}
        missing = required - set(reader.fieldnames)
        if missing:
            raise RuntimeError(f"{path}: missing columns: {sorted(missing)}")

        for row in reader:
            n_rows += 1
            if n_rows <= skip:
                continue

            try:
                rtt_ns = int(float(row["rtt_ns"]))
                oneway_ns_est = int(float(row["oneway_ns_est"]))
                wall_ns = int(float(row["wall_ns"]))
                cpu_ns = int(float(row["cpu_ns"]))
            except Exception:
                continue

            if drop_timeouts and rtt_ns <= 0:
                continue

            rtt.append(rtt_ns)
            oneway.append(oneway_ns_est)
            wall_last = max(wall_last, wall_ns)
            cpu_last = max(cpu_last, cpu_ns)

    if name is None:
        name = path

    return Stats(name=name, n=len(rtt), rtt_ns=rtt, oneway_ns=oneway, wall_ns_last=wall_last, cpu_ns_last=cpu_last)


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
    # Merge per-sample data into a single long-form file for plotting:
    # dataset,iter,counter,rtt_ns,oneway_ns_est,wall_ns,cpu_ns,cpu_pct
    with open(path, "w", newline="") as outf:
        w = csv.writer(outf)
        w.writerow(["dataset", "iter", "counter", "rtt_ns", "oneway_ns_est", "wall_ns", "cpu_ns", "cpu_pct"])

        for i, in_path in enumerate(csv_paths):
            dataset = names[i] if names else in_path

            with open(in_path, "r", newline="") as f:
                reader = csv.DictReader(f)
                if reader.fieldnames is None:
                    raise RuntimeError(f"{in_path}: missing header row")

                required = {"iter", "counter", "rtt_ns", "oneway_ns_est", "wall_ns", "cpu_ns", "cpu_pct"}
                missing = required - set(reader.fieldnames)
                if missing:
                    raise RuntimeError(f"{in_path}: missing columns: {sorted(missing)}")

                n_rows = 0
                for row in reader:
                    n_rows += 1
                    if n_rows <= skip:
                        continue

                    try:
                        rtt_ns = float(row["rtt_ns"])
                        if drop_timeouts and rtt_ns <= 0:
                            continue

                        w.writerow([
                            dataset,
                            row["iter"],
                            row["counter"],
                            row["rtt_ns"],
                            row["oneway_ns_est"],
                            row["wall_ns"],
                            row["cpu_ns"],
                            row["cpu_pct"],
                        ])
                    except Exception:
                        continue


def main():
    ap = argparse.ArgumentParser(
        description="Compare IPC benchmark CSVs (Fast DDS vs PPS, polling vs waitset, etc.)."
    )
    ap.add_argument("csv", nargs="+", help="CSV file(s) produced by sender (redirect stdout to a file).")
    ap.add_argument("--name", action="append", help="Optional display name per CSV (repeat to match csv args).")
    ap.add_argument("--skip", type=int, default=0, help="Skip first N data rows (after header).")
    ap.add_argument("--keep-timeouts", action="store_true", help="Keep rows with rtt_ns<=0 (default drops them).")

    ap.add_argument("--out-long", help="Write long-form combined CSV: dataset,metric,value")
    ap.add_argument("--out-wide", help="Write wide-form combined CSV: one row per dataset")
    ap.add_argument("--out-series", help="Write plot-ready per-sample merged CSV")

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
    