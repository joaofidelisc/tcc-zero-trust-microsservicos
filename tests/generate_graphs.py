"""Agrega qualquer experimento repetido, sem datas ou caminhos hardcoded."""

import argparse
from pathlib import Path

import matplotlib.pyplot as plt
import pandas as pd

SCENARIO_LABELS = {
    "scenario_1": "C1 — Baseline HTTP",
    "scenario_2": "C2 — HTTP + JWT",
    "scenario_3": "C3 — mTLS interno",
    "scenario_4": "C4 — mTLS interno + JWT",
    "scenario_5_k8s_baseline": "C5a — Kubernetes sem mesh",
    "scenario_5_mesh": "C5b — Kubernetes + Istio",
}


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
            }
        )
    if not rows:
        raise FileNotFoundError(f"nenhum results_stats.csv válido em {experiment_dir}")
    return pd.DataFrame(rows)


def summarize_runs(runs):
    numeric = [
        "requests",
        "failures",
        "throughput_rps",
        "latency_mean_ms",
        "latency_p50_ms",
        "latency_p95_ms",
    ]
    summary = runs.groupby(["scenario", "label"])[numeric].agg(["count", "mean", "std"])
    summary.columns = ["_".join(column) for column in summary.columns]
    return summary.reset_index()


def plot_distributions(runs, output_dir):
    order = [scenario for scenario in SCENARIO_LABELS if scenario in set(runs["scenario"])]
    labels = [SCENARIO_LABELS[scenario] for scenario in order]
    throughput = [
        runs.loc[runs["scenario"] == scenario, "throughput_rps"].tolist()
        for scenario in order
    ]
    latency = [
        runs.loc[runs["scenario"] == scenario, "latency_p95_ms"].tolist()
        for scenario in order
    ]

    figure, axes = plt.subplots(1, 2, figsize=(15, 6))
    axes[0].boxplot(throughput, tick_labels=labels, showmeans=True)
    axes[0].set_title("Distribuição da vazão entre repetições")
    axes[0].set_ylabel("Requisições por segundo")
    axes[1].boxplot(latency, tick_labels=labels, showmeans=True)
    axes[1].set_title("Distribuição da latência P95 entre repetições")
    axes[1].set_ylabel("Milissegundos")
    for axis in axes:
        axis.grid(axis="y", alpha=0.3)
        axis.tick_params(axis="x", rotation=25)
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
            rows.append(
                {
                    "round": resource_path.parents[1].name,
                    "scenario": scenario,
                    "cpu_mean": frame["cpu_numeric"].mean(),
                    "cpu_max": frame["cpu_numeric"].max(),
                    "unit": "percent",
                }
            )
        elif "cpu_millicores" in frame.columns:
            frame["cpu_numeric"] = pd.to_numeric(
                frame["cpu_millicores"], errors="coerce"
            )
            rows.append(
                {
                    "round": resource_path.parents[1].name,
                    "scenario": scenario,
                    "cpu_mean": frame["cpu_numeric"].mean(),
                    "cpu_max": frame["cpu_numeric"].max(),
                    "unit": "millicores",
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
    plot_distributions(runs, output_dir)

    resources = summarize_resources(experiment_dir)
    if not resources.empty:
        resources.to_csv(output_dir / "resource_summary_by_run.csv", index=False)

    print(f"Análise gerada em {output_dir}")


if __name__ == "__main__":
    main()
