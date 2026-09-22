#!/usr/bin/env bash
set -Eeuo pipefail

SCENARIO_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCENARIO_DIR/versions.env"
BIN_DIR="$SCENARIO_DIR/bin"
mkdir -p "$BIN_DIR"

for command_name in curl sha256sum tar install awk uname; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "Comando obrigatório ausente: $command_name" >&2
        exit 1
    fi
done

case "$(uname -m)" in
    x86_64) architecture="amd64" ;;
    aarch64|arm64) architecture="arm64" ;;
    *) echo "Arquitetura não suportada: $(uname -m)" >&2; exit 1 ;;
esac

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

curl -fsSLo "$tmp_dir/kind" "https://github.com/kubernetes-sigs/kind/releases/download/$KIND_VERSION/kind-linux-$architecture"
curl -fsSLo "$tmp_dir/kind.sha256sum" "https://github.com/kubernetes-sigs/kind/releases/download/$KIND_VERSION/kind-linux-$architecture.sha256sum"
kind_hash="$(awk '{print $1}' "$tmp_dir/kind.sha256sum")"
printf '%s  %s\n' "$kind_hash" "$tmp_dir/kind" | sha256sum -c -
install -m 0755 "$tmp_dir/kind" "$BIN_DIR/kind"

curl -fsSLo "$tmp_dir/kubectl" "https://dl.k8s.io/release/$KUBECTL_VERSION/bin/linux/$architecture/kubectl"
curl -fsSLo "$tmp_dir/kubectl.sha256" "https://dl.k8s.io/release/$KUBECTL_VERSION/bin/linux/$architecture/kubectl.sha256"
kubectl_hash="$(awk '{print $1}' "$tmp_dir/kubectl.sha256")"
printf '%s  %s\n' "$kubectl_hash" "$tmp_dir/kubectl" | sha256sum -c -
install -m 0755 "$tmp_dir/kubectl" "$BIN_DIR/kubectl"

curl -fsSLo "$tmp_dir/istio.tar.gz" "https://github.com/istio/istio/releases/download/$ISTIO_VERSION/istio-$ISTIO_VERSION-linux-$architecture.tar.gz"
curl -fsSLo "$tmp_dir/istio.sha256" "https://github.com/istio/istio/releases/download/$ISTIO_VERSION/istio-$ISTIO_VERSION-linux-$architecture.tar.gz.sha256"
istio_hash="$(awk '{print $1}' "$tmp_dir/istio.sha256")"
printf '%s  %s\n' "$istio_hash" "$tmp_dir/istio.tar.gz" | sha256sum -c -
tar -xzf "$tmp_dir/istio.tar.gz" -C "$tmp_dir"
install -m 0755 "$tmp_dir/istio-$ISTIO_VERSION/bin/istioctl" "$BIN_DIR/istioctl"

echo "Ferramentas verificadas e instaladas em $BIN_DIR"
