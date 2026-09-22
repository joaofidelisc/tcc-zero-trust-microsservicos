#!/usr/bin/env bash
set -Eeuo pipefail

CERT_DIR="$(cd "$(dirname "$0")" && pwd)"
FORCE="${1:-}"
umask 077

required_files="ca.key ca.crt service_a.key service_a.crt service_b.key service_b.crt"
for file_name in $required_files; do
    if [ -e "$CERT_DIR/$file_name" ] && [ "$FORCE" != "--force" ]; then
        echo "Certificados já existem em $CERT_DIR."
        echo "Use '$0 --force' somente se desejar substituí-los."
        exit 1
    fi
done

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

printf '%s\n' 'basicConstraints=critical,CA:FALSE' 'keyUsage=critical,digitalSignature,keyEncipherment' 'extendedKeyUsage=clientAuth' 'subjectAltName=DNS:service_a' > "$tmp_dir/service_a.ext"

printf '%s\n' 'basicConstraints=critical,CA:FALSE' 'keyUsage=critical,digitalSignature,keyEncipherment' 'extendedKeyUsage=serverAuth' 'subjectAltName=DNS:service_b' > "$tmp_dir/service_b.ext"

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$CERT_DIR/ca.key"
openssl req -x509 -new -sha256 -days 3650 -key "$CERT_DIR/ca.key" -out "$CERT_DIR/ca.crt" -subj "/C=BR/ST=SP/L=SaoPaulo/O=ZeroTrustLab/CN=ZeroTrustRootCA" -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" -addext "subjectKeyIdentifier=hash"

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$CERT_DIR/service_a.key"
openssl req -new -sha256 -key "$CERT_DIR/service_a.key" -out "$tmp_dir/service_a.csr" -subj "/C=BR/ST=SP/L=SaoPaulo/O=ZeroTrustLab/CN=service_a"
openssl x509 -req -sha256 -days 365 -in "$tmp_dir/service_a.csr" -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" -CAcreateserial -out "$CERT_DIR/service_a.crt" -extfile "$tmp_dir/service_a.ext"

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$CERT_DIR/service_b.key"
openssl req -new -sha256 -key "$CERT_DIR/service_b.key" -out "$tmp_dir/service_b.csr" -subj "/C=BR/ST=SP/L=SaoPaulo/O=ZeroTrustLab/CN=service_b"
openssl x509 -req -sha256 -days 365 -in "$tmp_dir/service_b.csr" -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" -CAcreateserial -out "$CERT_DIR/service_b.crt" -extfile "$tmp_dir/service_b.ext"

chmod 600 "$CERT_DIR"/*.key
chmod 644 "$CERT_DIR"/*.crt
echo "Certificados separados por identidade gerados em $CERT_DIR."
