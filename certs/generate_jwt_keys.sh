#!/usr/bin/env bash
# Gera, se ainda não existir, o par de chaves RSA de 3.072 bits usado para
# assinar (Checkout) e validar (Inventory ou Envoy) os JWT RS256 em todos os cenários.
set -Eeuo pipefail

CERT_DIR="$(cd "$(dirname "$0")" && pwd)"
umask 077

if [ ! -f "$CERT_DIR/jwt_private.pem" ]; then
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$CERT_DIR/jwt_private.pem"
fi
openssl pkey -in "$CERT_DIR/jwt_private.pem" -pubout -out "$CERT_DIR/jwt_public.pem"
# Os contêineres executam com usuário diferente do dono do arquivo; a chave fica legível
# apenas localmente e nunca é versionada (*.pem está no .gitignore).
chmod 644 "$CERT_DIR/jwt_private.pem" "$CERT_DIR/jwt_public.pem"
echo "Chaves JWT RS256 disponíveis em $CERT_DIR."
