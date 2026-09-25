"""Agrega qualquer experimento repetido, sem datas ou caminhos hardcoded."""

import argparse
from pathlib import Path

import matplotlib.pyplot as plt
import pandas as pd
from scipy.stats import mannwhitneyu

SCENARIO_LABELS = {
    "scenario_1": "C1 — HTTP sem proteção",
    "scenario_2": "C2 — HTTP + JWT RS256",
    "scenario_3": "C3 — mTLS na aplicação",
    "scenario_4": "C4 — mTLS + JWT na aplicação",
    "scenario_5_k8s_baseline": "C5a — Kubernetes sem malha",
    "scenario_5_mesh": "C5b — Kubernetes + Istio",
}

# Pares comparados: dentro de cada plataforma e, para caracterizar a plataforma, C1 × C5a.
COMPARISONS = [
    ("scenario_1", "scenario_2"),
    ("scenario_1", "scenario_3"),
    ("scenario_1", "scenario_4"),
    ("scenario_5_k8s_baseline", "scenario_5_mesh"),
    ("scenario_1", "scenario_5_k8s_baseline"),
    # Mesmos controles na aplicação e na malha (assinatura no Checkout em ambos).
    ("scenario_2", "scenario_5_mesh"),
    ("scenario_4", "scenario_5_mesh"),
]
METRICS = ["throughput_rps", "latency_mean_ms", "latency_p50_ms", "latency_p95_ms"]


def newest_experiment(runs_dir):
    candidates = sorted(path for path in runs_dir.glob("experiment_*") if path.is_dir())
    if not candidates:
        raise FileNotFoundError(f"nenhum experimento encontrado em {runs_dir}")
    return candidates[-1]


def load_runs(experiment_dir):
    rows = []
    for stats_path in sorted(experiment_dir.glob("round_*/*/results_stats.csv")):
        scenario = stats_path.parent.name
        frame = pd.read_csv(stats_path)
        aggregated = frame[frame["Name"] == "Aggregated"]
        if aggregated.empty:
            continue
        row = aggregated.iloc[0]
        rows.append(
            {
                "round": stats_path.parents[1].name,
                "scenario": scenario,
                "label": SCENARIO_LABELS.get(scenario, scenario),
                "requests": float(row["Request Count"]),
                "failures": float(row["Failure Count"]),
                "throughput_rps": float(row["Requests/s"]),
                "latency_mean_ms": float(row["Average Response Time"]),
                "latency_p50_ms": float(row["50%"]),
                "latency_p95_ms": float(row["95%"]),
                "latency_p99_ms": float(row["99%"]),
            }
        )
    if not rows:
        raise FileNotFoundError(f"nenhum results_stats.csv válido em {experiment_dir}")
    return pd.DataFrame(rows)


def q1(series):
    return series.quantile(0.25)


def q3(series):
    return series.quantile(0.75)


def summarize_runs(runs):
    numeric = ["requests", "failures", *METRICS, "latency_p99_ms"]
    # std do pandas é amostral (n − 1).
    summary = runs.groupby(["scenario", "label"])[numeric].agg(
        ["count", "mean", "std", "median", q1, q3, "min", "max"]
    )
    summary.columns = ["_".join(column) for column in summary.columns]
    return summary.reset_index()


def compare_scenarios(runs):
    rows = []
    for reference, target in COMPARISONS:
        ref = runs[runs["scenario"] == reference]
        tgt = runs[runs["scenario"] == target]
        if ref.empty or tgt.empty:
            continue
        for metric in METRICS:
            ref_median = ref[metric].median()
            tgt_median = tgt[metric].median()
            test = mannwhitneyu(tgt[metric], ref[metric], alternative="two-sided")
            rows.append(
                {
                    "reference": reference,
                    "target": target,
                    "metric": metric,
                    "n_reference": len(ref),
                    "n_target": len(tgt),
                    "median_reference": ref_median,
                    "median_target": tgt_median,
                    "median_diff_percent": 100 * (tgt_median / ref_median - 1),
                    "mean_diff_percent": 100 * (tgt[metric].mean() / ref[metric].mean() - 1),
                    "mann_whitney_u": test.statistic,
                    "p_value": test.pvalue,
                }
            )
    return pd.DataFrame(rows)


def container_role(container):
    name = container.lower()
    service = "checkout" if ("service_a" in name or "service-a" in name) else "inventory"
    component = "sidecar" if "istio-proxy" in name else "app"
    return f"{service}_{component}"


def summarize_cpu_stat(experiment_dir, runs):
    """CPU exata por contêiner na janela medida, a partir dos contadores do cgroup v2."""
    rows = []
    requests = runs.set_index(["round", "scenario"])["requests"]
    for stat_path in sorted(experiment_dir.glob("round_*/*/cpu_stat.csv")):
        frame = pd.read_csv(stat_path)
        round_name, scenario = stat_path.parents[1].name, stat_path.parent.name
        pivot = frame.pivot_table(index=["container", "key"], columns="phase", values="value", aggfunc="first")
        if not {"start", "end"} <= set(pivot.columns):
            continue
        delta = (pivot["end"] - pivot["start"]).unstack("key")
        n_requests = requests.get((round_name, scenario))
        for container, values in delta.iterrows():
            usage_ms = values.get("usage_usec", float("nan")) / 1000
            periods = values.get("nr_periods", 0)
            rows.append(
                {
                    "round": round_name,
                    "scenario": scenario,
                    "container": container,
                    "role": container_role(container),
                    "cpu_ms": usage_ms,
                    "cpu_ms_per_request": usage_ms / n_requests if n_requests else float("nan"),
                    "throttled_periods_percent": 100 * values.get("nr_throttled", 0) / periods if periods else 0.0,
                    "throttled_ms": values.get("throttled_usec", 0) / 1000,
                }
            )
    return pd.DataFrame(rows)


def parse_memory_mib(value):
    text = str(value).strip()
    for suffix, factor in (("GiB", 1024), ("MiB", 1), ("KiB", 1 / 1024), ("kB", 1 / 1024), ("B", 1 / 1048576)):
        if text.endswith(suffix):
            return float(text[: -len(suffix)]) * factor
    return float(text)


def summarize_memory(experiment_dir):
    """Mediana e máximo da memória por contêiner em cada execução (docker stats / kubectl top)."""
    rows = []
    for resource_path in sorted(experiment_dir.glob("round_*/*/resources.csv")):
        frame = pd.read_csv(resource_path)
        if "memory_usage" in frame.columns:
            frame["mem_mib"] = frame["memory_usage"].map(parse_memory_mib)
            frame["name"] = frame["container"]
        elif "mem_mib" in frame.columns:
            frame["name"] = frame["pod"] + "/" + frame["container"]
        else:
            continue
        for name, group in frame.groupby("name"):
            rows.append(
                {
                    "round": resource_path.parents[1].name,
                    "scenario": resource_path.parent.name,
                    "role": container_role(name),
                    "mem_mib_median": group["mem_mib"].median(),
                    "mem_mib_max": group["mem_mib"].max(),
                }
            )
    return pd.DataFrame(rows)


def summarize_host(experiment_dir):
    rows = []
    for host_path in sorted(experiment_dir.glob("round_*/*/host.csv")):
        frame = pd.read_csv(host_path)
        if frame.empty:
            continue
        rows.append(
            {
                "round": host_path.parents[1].name,
                "scenario": host_path.parent.name,
                "host_cpu_busy_mean": frame["cpu_busy_percent"].mean(),
                "host_cpu_busy_max": frame["cpu_busy_percent"].max(),
                "cpu_mhz_mean": frame["cpu_mhz_mean"].mean(),
                "temp_max_c": frame["temp_max_c"].max(),
            }
        )
    return pd.DataFrame(rows)


def locust_warnings(experiment_dir):
    rows = []
    for log_path in sorted(experiment_dir.glob("round_*/*/locust.log")):
        text = log_path.read_text(errors="replace")
        rows.append(
            {
                "round": log_path.parents[1].name,
                "scenario": log_path.parent.name,
                "cpu_warning": "CPU usage above 90%" in text,
            }
        )
    return pd.DataFrame(rows)


def plot_distributions(runs, output_dir):
    order = [scenario for scenario in SCENARIO_LABELS if scenario in set(runs["scenario"])]
    labels = [SCENARIO_LABELS[scenario].split(" — ")[0] for scenario in order]
    figure, axes = plt.subplots(1, 2, figsize=(12, 5))
    for axis, metric, ylabel in (
        (axes[0], "throughput_rps", "Vazão (req/s)"),
        (axes[1], "latency_mean_ms", "Latência média (ms)"),
    ):
        data = [runs.loc[runs["scenario"] == scenario, metric].tolist() for scenario in order]
        axis.boxplot(data, tick_labels=labels, showmeans=True)
        axis.set_ylabel(ylabel)
    figure.tight_layout()
    figure.savefig(output_dir / "performance_distributions.png", dpi=160)
    plt.close(figure)


def summarize_resources(experiment_dir):
    rows = []
    for resource_path in sorted(experiment_dir.glob("round_*/*/resources.csv")):
        frame = pd.read_csv(resource_path)
        scenario = resource_path.parent.name
        if "cpu_percent" in frame.columns:
            frame["cpu_numeric"] = pd.to_numeric(
                frame["cpu_percent"].astype(str).str.rstrip("%"), errors="coerce"
            )
            unit = "percent"
        elif "cpu_millicores" in frame.columns:
            frame["cpu_numeric"] = pd.to_numeric(frame["cpu_millicores"], errors="coerce")
            unit = "millicores"
        else:
            continue
        rows.append(
            {
                "round": resource_path.parents[1].name,
                "scenario": scenario,
                "cpu_mean": frame["cpu_numeric"].mean(),
                "cpu_max": frame["cpu_numeric"].max(),
                "unit": unit,
            }
        )
    return pd.DataFrame(rows)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "experiment_dir",
        nargs="?",
        type=Path,
        help="diretório tests/runs/experiment_...; usa o mais recente se omitido",
    )
    arguments = parser.parse_args()
    tests_dir = Path(__file__).resolve().parent
    experiment_dir = arguments.experiment_dir or newest_experiment(tests_dir / "runs")
    experiment_dir = experiment_dir.resolve()
    output_dir = experiment_dir / "analysis"
    output_dir.mkdir(parents=True, exist_ok=True)

    runs = load_runs(experiment_dir)
    runs.to_csv(output_dir / "runs.csv", index=False)
    summarize_runs(runs).to_csv(output_dir / "summary_by_scenario.csv", index=False)
    comparisons = compare_scenarios(runs)
    if not comparisons.empty:
        comparisons.to_csv(output_dir / "comparisons.csv", index=False)
    plot_distributions(runs, output_dir)

    for name, frame in (
        ("resource_summary_by_run.csv", summarize_resources(experiment_dir)),
        ("cpu_stat_by_run.csv", summarize_cpu_stat(experiment_dir, runs)),
        ("host_by_run.csv", summarize_host(experiment_dir)),
        ("memory_by_run.csv", summarize_memory(experiment_dir)),
        ("locust_warnings.csv", locust_warnings(experiment_dir)),
    ):
        if not frame.empty:
            frame.to_csv(output_dir / name, index=False)

    cpu = summarize_cpu_stat(experiment_dir, runs)
    if not cpu.empty:
        cpu.groupby(["scenario", "role"])[["cpu_ms_per_request", "throttled_periods_percent"]].median().to_csv(
            output_dir / "cpu_per_request_median.csv"
        )

    print(f"Análise gerada em {output_dir}")


if __name__ == "__main__":
    main()
