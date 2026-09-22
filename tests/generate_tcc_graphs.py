import argparse
from pathlib import Path
import matplotlib.pyplot as plt
import pandas as pd

def parse_docker_memory(mem_str):
    mem_str = str(mem_str).strip()
    if 'MiB' in mem_str:
        return float(mem_str.replace('MiB', ''))
    elif 'GiB' in mem_str:
        return float(mem_str.replace('GiB', '')) * 1024
    elif 'KiB' in mem_str:
        return float(mem_str.replace('KiB', '')) / 1024
    elif 'B' in mem_str:
        return float(mem_str.replace('B', '')) / (1024 * 1024)
    return float(mem_str)

def plot_docker_scenario(scenario_dir, output_dir, scenario_name, title):
    resources_path = scenario_dir / "resources.csv"
    if not resources_path.exists():
        print(f"File not found: {resources_path}")
        return

    df = pd.read_csv(resources_path)
    df['timestamp'] = pd.to_datetime(df['timestamp'])
    df['seconds'] = (df['timestamp'] - df['timestamp'].min()).dt.total_seconds()
    
    df['cpu'] = df['cpu_percent'].str.rstrip('%').astype(float)
    df['mem_mib'] = df['memory_usage'].apply(parse_docker_memory)

    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(10, 8))
    
    for container in df['container'].unique():
        label = 'Service A (Checkout)' if 'service_a' in container else 'Service B (Inventory)'
        container_data = df[df['container'] == container]
        ax1.plot(container_data['seconds'], container_data['cpu'], label=label, marker='o', markersize=3)
        ax2.plot(container_data['seconds'], container_data['mem_mib'], label=label, marker='s', markersize=3)
        
    ax1.set_title(f"{title} - Uso de CPU")
    ax1.set_ylabel("CPU (%)")
    ax1.set_xlabel("Tempo (segundos)")
    ax1.grid(True, linestyle='--', alpha=0.7)
    ax1.legend()
    
    ax2.set_title(f"{title} - Uso de Memória")
    ax2.set_ylabel("Memória (MiB)")
    ax2.set_xlabel("Tempo (segundos)")
    ax2.grid(True, linestyle='--', alpha=0.7)
    ax2.legend()
    
    plt.tight_layout()
    output_path = output_dir / f"{scenario_name}_cpu_mem.png"
    plt.savefig(output_path, dpi=150)
    plt.close()
    print(f"Gráfico salvo em {output_path}")

def plot_k8s_scenario(scenario_dir, output_dir, scenario_name, title):
    resources_path = scenario_dir / "resources.csv"
    if not resources_path.exists():
        print(f"File not found: {resources_path}")
        return

    df = pd.read_csv(resources_path)
    df['timestamp'] = pd.to_datetime(df['timestamp'])
    df['seconds'] = (df['timestamp'] - df['timestamp'].min()).dt.total_seconds()
    
    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(12, 10))
    
    # We want to separate by pod AND container.
    # Service A (Python vs Envoy), Service B (Python vs Envoy)
    for pod in df['pod'].unique():
        service_name = 'Service A' if 'service-a' in pod else 'Service B'
        pod_data = df[df['pod'] == pod]
        
        for container in pod_data['container'].unique():
            container_data = pod_data[pod_data['container'] == container]
            
            if container == 'istio-proxy':
                label = f"{service_name} (Envoy Sidecar)"
                linestyle = '--'
                marker = 'x'
            else:
                label = f"{service_name} (App Python)"
                linestyle = '-'
                marker = 'o'
                
            ax1.plot(container_data['seconds'], container_data['cpu_millicores'], label=label, linestyle=linestyle, marker=marker, markersize=3)
            ax2.plot(container_data['seconds'], container_data['mem_mib'], label=label, linestyle=linestyle, marker=marker, markersize=3)

    ax1.set_title(f"{title} - Uso de CPU (millicores)")
    ax1.set_ylabel("CPU (millicores)")
    ax1.set_xlabel("Tempo (segundos)")
    ax1.grid(True, linestyle='--', alpha=0.7)
    ax1.legend()
    
    ax2.set_title(f"{title} - Uso de Memória (MiB)")
    ax2.set_ylabel("Memória (MiB)")
    ax2.set_xlabel("Tempo (segundos)")
    ax2.grid(True, linestyle='--', alpha=0.7)
    ax2.legend()
    
    plt.tight_layout()
    output_path = output_dir / f"{scenario_name}_cpu_mem.png"
    plt.savefig(output_path, dpi=150)
    plt.close()
    print(f"Gráfico salvo em {output_path}")

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("experiment_dir", type=Path)
    args = parser.parse_args()
    
    experiment_dir = args.experiment_dir.resolve()
    output_dir = experiment_dir / "graficos_tcc"
    output_dir.mkdir(parents=True, exist_ok=True)
    
    round_dir = experiment_dir / "round_01"
    if not round_dir.exists():
        print(f"round_01 não encontrado em {experiment_dir}")
        return

    scenarios = {
        "scenario_1": "Cenário 1 (Baseline Arquitetural)",
        "scenario_2": "Cenário 2 (Validação de Aplicação JWT)",
        "scenario_3": "Cenário 3 (Validação de Infraestrutura - mTLS)",
        "scenario_4": "Cenário 4 (Zero Trust via Código - mTLS + JWT)"
    }
    
    for s_name, s_title in scenarios.items():
        s_dir = round_dir / s_name
        if s_dir.exists():
            plot_docker_scenario(s_dir, output_dir, s_name, s_title)
            
    # K8s scenarios
    if (round_dir / "scenario_5_k8s_baseline").exists():
        plot_k8s_scenario(round_dir / "scenario_5_k8s_baseline", output_dir, "scenario_5_baseline", "Cenário 5a (Kubernetes Sem Mesh)")
    
    if (round_dir / "scenario_5_mesh").exists():
        plot_k8s_scenario(round_dir / "scenario_5_mesh", output_dir, "scenario_5_mesh", "Cenário 5b (Abstração via Service Mesh Istio)")
        
if __name__ == "__main__":
    main()
