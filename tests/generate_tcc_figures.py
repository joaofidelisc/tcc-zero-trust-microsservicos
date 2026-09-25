"""Gera as figuras e tabelas do TCC no padrão do manual USP/Esalq.

Gráficos sem título, sem grade e sem borda superior/direita, eixos pretos de 1,5 pt,
painéis identificados por letra maiúscula no canto superior esquerdo.

Uso: python tests/generate_tcc_figures.py tests/runs/experiment_... pasta_das_figuras [--tabelas pasta_das_tabelas]
"""

import argparse
from pathlib import Path

import matplotlib.pyplot as plt
import pandas as pd
from matplotlib.patches import FancyArrowPatch, FancyBboxPatch

ORDER = [
    "scenario_1",
    "scenario_2",
    "scenario_3",
    "scenario_4",
    "scenario_5_k8s_baseline",
    "scenario_5_mesh",
]
SHORT = dict(zip(ORDER, ["C1", "C2", "C3", "C4", "C5a", "C5b"]))
ROLE_LABELS = {
    "checkout_app": "Checkout",
    "inventory_app": "Inventory",
    "checkout_sidecar": "Envoy do Checkout",
    "inventory_sidecar": "Envoy do Inventory",
}
ROLE_COLORS = {
    "checkout_app": "#2b2b2b",
    "inventory_app": "#8c8c8c",
    "checkout_sidecar": "#c9c9c9",
    "inventory_sidecar": "#ffffff",
}

plt.rcParams.update(
    {
        "font.family": ["Liberation Sans", "Arial", "DejaVu Sans"],
        "font.size": 10,
        "axes.linewidth": 1.5,
        "axes.edgecolor": "black",
        "axes.grid": False,
        "xtick.color": "black",
        "ytick.color": "black",
        "savefig.dpi": 300,
    }
)


def style_axis(axis):
    axis.spines["top"].set_visible(False)
    axis.spines["right"].set_visible(False)
    axis.tick_params(width=1.5)


def panel_letter(axis, letter, x=-0.14, y=1.04):
    axis.text(x, y, letter, transform=axis.transAxes, fontsize=12, fontweight="bold", va="bottom")


def figure_distributions(runs, output_dir):
    labels = [SHORT[s] for s in ORDER]
    figure, axes = plt.subplots(1, 2, figsize=(9, 3.6))
    for axis, metric, ylabel, letter in (
        (axes[0], "throughput_rps", "Vazão (req/s)", "A"),
        (axes[1], "latency_mean_ms", "Latência média (ms)", "B"),
    ):
        data = [runs.loc[runs["scenario"] == s, metric].tolist() for s in ORDER]
        axis.boxplot(
            data,
            tick_labels=labels,
            widths=0.55,
            medianprops={"color": "black", "linewidth": 1.5},
            boxprops={"linewidth": 1.0},
            whiskerprops={"linewidth": 1.0},
            capprops={"linewidth": 1.0},
            flierprops={"marker": "o", "markersize": 3, "markerfacecolor": "black"},
        )
        axis.set_ylabel(ylabel)
        axis.set_xlabel("Configuração")
        axis.set_ylim(bottom=0)
        style_axis(axis)
        panel_letter(axis, letter)
    figure.tight_layout()
    figure.savefig(output_dir / "figura_2_vazao_latencia.png")
    plt.close(figure)


def figure_cpu(cpu, output_dir):
    medians = cpu.groupby(["scenario", "role"])["cpu_ms_per_request"].median().unstack("role").reindex(ORDER)
    roles = [r for r in ROLE_LABELS if r in medians.columns]
    figure, axis = plt.subplots(figsize=(7.5, 3.8))
    bottom = pd.Series(0.0, index=medians.index)
    positions = range(len(ORDER))
    for role in roles:
        values = medians[role].fillna(0.0)
        axis.bar(
            positions,
            values,
            bottom=bottom,
            width=0.6,
            color=ROLE_COLORS[role],
            edgecolor="black",
            linewidth=0.8,
            label=ROLE_LABELS[role],
        )
        bottom += values
    axis.set_xticks(list(positions), [SHORT[s] for s in ORDER])
    axis.set_xlabel("Configuração")
    axis.set_ylabel("CPU por requisição (ms)")
    axis.legend(frameon=False, fontsize=9, loc="lower center", bbox_to_anchor=(0.5, 1.0), ncol=4)
    style_axis(axis)
    figure.tight_layout()
    figure.savefig(output_dir / "figura_3_cpu_por_requisicao.png")
    plt.close(figure)


def box(axis, x, y, w, h, text, fill="white", fontsize=7.5, dashed=False):
    patch = FancyBboxPatch(
        (x, y), w, h, boxstyle="round,pad=0.02", linewidth=1.0,
        edgecolor="black", facecolor=fill, linestyle="--" if dashed else "-",
    )
    axis.add_patch(patch)
    axis.text(x + w / 2, y + h / 2, text, ha="center", va="center", fontsize=fontsize)


def arrow(axis, x1, y1, x2, y2, text="", dy=0.07, fontsize=6.5):
    axis.add_patch(FancyArrowPatch((x1, y1), (x2, y2), arrowstyle="-|>", mutation_scale=8, linewidth=1.0, color="black"))
    if text:
        axis.text((x1 + x2) / 2, y1 + dy, text, ha="center", va="bottom", fontsize=fontsize)


def figure_architecture(output_dir):
    """Figura 1: fluxo das seis configurações (painéis A–F)."""
    panels = [
        ("A", "C1 (Docker)", "HTTP", "", ""),
        ("B", "C2 (Docker)", "HTTP + JWT", "assina RS256", "valida RS256"),
        ("C", "C3 (Docker)", "mTLS", "certificado de cliente", "certificado de servidor"),
        ("D", "C4 (Docker)", "mTLS + JWT", "assina RS256\ncertificado de cliente", "valida RS256\ncertificado de servidor"),
        ("E", "C5a (Kubernetes)", "HTTP", "", ""),
        ("F", "C5b (Kubernetes + Istio)", "", "", ""),
    ]
    figure, axes = plt.subplots(3, 2, figsize=(9, 5.4))
    for axis, (letter, name, link, left_note, right_note) in zip(axes.flat, panels):
        axis.set_xlim(0, 1)
        axis.set_ylim(0, 1)
        axis.axis("off")
        axis.text(0.0, 1.0, letter, fontsize=12, fontweight="bold", va="top")
        axis.text(0.07, 0.985, name, fontsize=8.5, va="top")
        box(axis, 0.03, 0.40, 0.14, 0.22, "Locust", fill="#eeeeee")
        if letter != "F":
            box(axis, 0.31, 0.36, 0.24, 0.30, "Checkout")
            box(axis, 0.74, 0.36, 0.24, 0.30, "Inventory")
            arrow(axis, 0.18, 0.51, 0.31, 0.51, "HTTP")
            arrow(axis, 0.56, 0.51, 0.74, 0.51, link)
            if left_note:
                axis.text(0.43, 0.29, left_note, ha="center", va="top", fontsize=6.5)
            if right_note:
                axis.text(0.86, 0.29, right_note, ha="center", va="top", fontsize=6.5)
        else:
            # cada aplicação e seu Envoy no mesmo pod (contorno tracejado)
            box(axis, 0.27, 0.04, 0.28, 0.74, "", dashed=True)
            box(axis, 0.70, 0.04, 0.28, 0.74, "", dashed=True)
            axis.text(0.41, 0.82, "pod do Checkout", ha="center", fontsize=6.5)
            axis.text(0.84, 0.82, "pod do Inventory", ha="center", fontsize=6.5)
            box(axis, 0.30, 0.50, 0.22, 0.22, "Checkout\n(assina RS256)", fontsize=7)
            box(axis, 0.30, 0.10, 0.22, 0.24, "Envoy", fill="#dddddd")
            box(axis, 0.73, 0.50, 0.22, 0.22, "Inventory")
            box(axis, 0.73, 0.10, 0.22, 0.24, "Envoy\n(mTLS estrito,\nvalida RS256)", fill="#dddddd", fontsize=6.3)
            arrow(axis, 0.18, 0.46, 0.30, 0.25, "")
            axis.text(0.20, 0.30, "HTTP", fontsize=6.5, ha="center")
            axis.add_patch(FancyArrowPatch((0.41, 0.34), (0.41, 0.50), arrowstyle="<|-|>", mutation_scale=7, linewidth=0.8, color="black"))
            axis.add_patch(FancyArrowPatch((0.84, 0.34), (0.84, 0.50), arrowstyle="<|-|>", mutation_scale=7, linewidth=0.8, color="black"))
            arrow(axis, 0.52, 0.22, 0.73, 0.22, "mTLS\n+ JWT", dy=0.03, fontsize=6)
    figure.tight_layout()
    figure.savefig(output_dir / "figura_1_configuracoes.png")
    plt.close(figure)


def fmt(value, decimals=2):
    return f"{value:,.{decimals}f}".replace(",", "X").replace(".", ",").replace("X", ".")


def tables(analysis_dir, output_dir):
    runs = pd.read_csv(analysis_dir / "runs.csv")
    comparisons = pd.read_csv(analysis_dir / "comparisons.csv")
    reference = {"scenario_2": "scenario_1", "scenario_3": "scenario_1", "scenario_4": "scenario_1",
                 "scenario_5_mesh": "scenario_5_k8s_baseline"}
    lines = [
        "| Configuração | Vazão (req/s) | Dif. (%) | Latência média (ms) | Dif. (%) | P50 (ms) | P95 (ms) |",
        "|---|--:|--:|--:|--:|--:|--:|",
    ]
    for scenario in ORDER:
        group = runs[runs["scenario"] == scenario]
        row = [SHORT[scenario]]
        for metric in ("throughput_rps", "latency_mean_ms"):
            q1, med, q3 = group[metric].quantile([0.25, 0.5, 0.75])
            row.append(f"{fmt(med)}<br>({fmt(q1)}–{fmt(q3)})")  # mediana e, abaixo, o IIQ
            ref = reference.get(scenario)
            if ref:
                c = comparisons[(comparisons.reference == ref) & (comparisons.target == scenario) & (comparisons.metric == metric)].iloc[0]
                row.append(f"{'+' if c.median_diff_percent > 0 else ''}{fmt(c.median_diff_percent, 1)}".replace("-", "−"))
            else:
                row.append("referência")
        row.append(fmt(group["latency_p50_ms"].median(), 0))
        row.append(fmt(group["latency_p95_ms"].median(), 0))
        lines.append("| " + " | ".join(row) + " |")
    (output_dir / "tabela_3.md").write_text("\n".join(lines) + "\n")

    cpu = pd.read_csv(analysis_dir / "cpu_stat_by_run.csv")
    memory = pd.read_csv(analysis_dir / "memory_by_run.csv")
    cpu_med = cpu.groupby(["scenario", "role"])["cpu_ms_per_request"].median().unstack("role")
    throttle = cpu[cpu.role == "checkout_app"].groupby("scenario")["throttled_periods_percent"].median()
    mem_med = memory.groupby(["scenario", "role"])["mem_mib_median"].median().unstack("role")
    total = cpu.groupby(["round", "scenario"])["cpu_ms_per_request"].sum().groupby("scenario").median()
    lines = [
        "| Configuração | CPU do Checkout (ms) | CPU do Inventory (ms) | CPU dos Envoy (ms) | CPU total (ms) | Períodos estrangulados do Checkout (%) | Memória do Checkout (MiB) |",
        "|---|--:|--:|--:|--:|--:|--:|",
    ]
    for scenario in ORDER:
        sidecars = sum(cpu_med.loc[scenario].get(r, 0) or 0 for r in ("checkout_sidecar", "inventory_sidecar")
                       if pd.notna(cpu_med.loc[scenario].get(r)))
        lines.append(
            "| " + " | ".join([
                SHORT[scenario],
                fmt(cpu_med.loc[scenario, "checkout_app"]),
                fmt(cpu_med.loc[scenario, "inventory_app"]),
                fmt(sidecars) if sidecars else "–",
                fmt(total[scenario]),
                fmt(throttle[scenario], 1),
                fmt(mem_med.loc[scenario, "checkout_app"], 1),
            ]) + " |"
        )
    (output_dir / "tabela_4.md").write_text("\n".join(lines) + "\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("experiment_dir", type=Path)
    parser.add_argument("output_dir", type=Path)
    parser.add_argument("--tabelas", type=Path, help="pasta das tabelas (padrão: a das figuras)")
    args = parser.parse_args()
    analysis_dir = args.experiment_dir / "analysis"
    args.output_dir.mkdir(parents=True, exist_ok=True)
    runs = pd.read_csv(analysis_dir / "runs.csv")
    cpu = pd.read_csv(analysis_dir / "cpu_stat_by_run.csv")
    figure_architecture(args.output_dir)
    figure_distributions(runs, args.output_dir)
    figure_cpu(cpu, args.output_dir)
    tables_dir = args.tabelas or args.output_dir
    tables_dir.mkdir(parents=True, exist_ok=True)
    tables(analysis_dir, tables_dir)
    print(f"Figuras e tabelas geradas em {args.output_dir}")


if __name__ == "__main__":
    main()
