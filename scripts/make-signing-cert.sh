#!/bin/bash
# Cria um certificado de assinatura de código self-signed no keychain de LOGIN.
#
# Por que isto existe: com assinatura ad-hoc (`codesign -s -`), o Designated Requirement
# do app degenera para igualdade de cdhash. Como o cdhash muda a cada build, o macOS trata
# cada compilação como um app diferente e re-pede a permissão de captura de áudio toda
# vez. Um certificado nomeado ancora o DR no próprio certificado, e a permissão persiste.
#
# Vai para o keychain de login, não o do sistema: pede no máximo a SUA senha, nunca a de
# administrador. É substituível por um Developer ID assim que a conta Apple sair — basta
# exportar CODESIGN_IDENTITY antes de rodar o make-app.sh.
set -euo pipefail

CERT_NAME="${1:-Capita Development}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$CERT_NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "✓ Certificado '$CERT_NAME' já existe. Nada a fazer."
    exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "▸ Gerando certificado '$CERT_NAME'"
cat > "$WORK/openssl.cnf" <<'CONF'
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no

[dn]
CN = CERT_COMMON_NAME

[v3]
basicConstraints     = critical,CA:false
keyUsage             = critical,digitalSignature
extendedKeyUsage     = critical,codeSigning
CONF
sed -i '' "s/CERT_COMMON_NAME/$CERT_NAME/" "$WORK/openssl.cnf"

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -config "$WORK/openssl.cnf" 2>/dev/null

# Duas incompatibilidades do OpenSSL 3 com o `security` da Apple, ambas descobertas na
# prática: (1) o formato PKCS#12 moderno (AES-256-CBC, MAC SHA-256) é rejeitado com
# "MAC verification failed" — daí o `-legacy`; (2) senha vazia também falha, então usamos
# uma senha de transporte. Ela não protege nada: o arquivo vive segundos num diretório
# temporário que o trap apaga, e nunca sai daqui.
TRANSPORT_PASSWORD="capita-transport"
openssl pkcs12 -export -legacy \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/cert.p12" -passout "pass:$TRANSPORT_PASSWORD" 2>/dev/null

echo "▸ Importando no keychain de login"
echo "  (o macOS pode pedir a SUA senha — não a de administrador)"
security import "$WORK/cert.p12" -k "$KEYCHAIN" -P "$TRANSPORT_PASSWORD" \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null

# Sem isto, o codesign trava pedindo autorização a cada uso da chave privada.
security set-key-partition-list -S apple-tool:,apple: -k "" "$KEYCHAIN" >/dev/null 2>&1 || true

echo "▸ Marcando como confiável para assinatura de código"
if ! security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem" 2>/dev/null; then
    echo "  (não foi possível ajustar a confiança automaticamente — normalmente tudo bem;"
    echo "   se o codesign reclamar, marque 'Sempre Confiar' no Acesso às Chaves)"
fi

echo
if security find-identity -v -p codesigning | grep -q "$CERT_NAME"; then
    echo "✓ Pronto. O make-app.sh vai usar '$CERT_NAME' automaticamente."
else
    echo "⚠ O certificado foi criado mas não aparece como identidade de assinatura."
    echo "  Abra o Acesso às Chaves, ache '$CERT_NAME' e marque"
    echo "  'Confiar' → 'Assinatura de código' → 'Sempre Confiar'."
    exit 1
fi
