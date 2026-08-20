#!/bin/bash
# Assina com Developer ID, notariza e grampeia o DMG — o caminho inteiro da distribuição.
#
# Sem isto o DMG serve só para esta máquina: ao ser transferido ele herda a quarentena, e
# o macOS 26 se recusa a abrir o app — a única opção que oferece é "Mover para o Lixo".
# Nenhum aviso menciona assinatura, então o sintoma parece um app quebrado.
#
# Notarizar é a Apple carimbar que o binário passou pela análise automática dela.
# "Grampear" (staple) anexa esse carimbo ao arquivo, para o Gatekeeper não precisar de
# internet na máquina de destino — que é justamente a máquina onde ninguém vai depurar.
#
# Precisa de duas coisas que não moram no repositório:
#
#   1. Um certificado "Developer ID Application" no keychain de login. Vem da conta paga
#      do Apple Developer Program: Xcode > Settings > Accounts > Manage Certificates >
#      "+" > Developer ID Application.
#
#   2. Credenciais do notarytool, guardadas uma vez no keychain:
#
#        xcrun notarytool store-credentials capita \
#            --apple-id SEU@EMAIL --team-id SEUTEAMID --password SENHA-DE-APP
#
#      A senha é uma "app-specific password" criada em appleid.apple.com — nunca a senha
#      da conta. O nome do perfil ("capita") é o que o NOTARY_PROFILE espera.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

APP="$ROOT/build/Capita.app"
DMG="$ROOT/build/Capita.dmg"
PROFILE="${NOTARY_PROFILE:-capita}"

# MARK: - Pré-requisitos, conferidos antes de gastar meia hora de upload

IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -oE '"Developer ID Application[^"]*"' | head -1 | tr -d '"') || true
fi

if [ -z "$IDENTITY" ]; then
    cat <<'MISSING'
✗ Nenhum certificado "Developer ID Application" neste keychain.

  É o único que a notarização aceita — o certificado local ("Capita Development") serve
  para desenvolver e não para distribuir.

  Como criar, com a conta do Apple Developer Program já adicionada ao Xcode:

    Xcode > Settings… (⌘,) > Accounts
      escolha a sua Apple ID > "Manage Certificates…"
      botão "+" no canto inferior esquerdo > "Developer ID Application"

  Se essa opção estiver ausente ou desabilitada, a conta ainda não é do Developer
  Program pago (US$ 99/ano) ou não tem o papel de Account Holder/Admin.

  Depois disso, rode este script de novo.
MISSING
    exit 1
fi

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    cat <<MISSING
✗ Não há credenciais do notarytool no perfil "$PROFILE".

  Guarde-as uma vez (a senha é uma app-specific password de appleid.apple.com, não a
  senha da conta):

    xcrun notarytool store-credentials $PROFILE \\
        --apple-id SEU@EMAIL --team-id SEUTEAMID --password SENHA-DE-APP

  O Team ID de dez caracteres aparece em developer.apple.com > Membership.
MISSING
    exit 1
fi

echo "▸ Identidade: $IDENTITY"
echo "▸ Perfil de notarização: $PROFILE"
echo

# MARK: - Build assinado para distribuição

CODESIGN_IDENTITY="$IDENTITY" "$ROOT/scripts/make-app.sh"

echo
echo "▸ Conferindo a assinatura do app"
codesign --verify --strict --deep --verbose=1 "$APP"

# O hardened runtime é o que a notarização exige e o que fecha o áudio por padrão. Se o
# entitlement de áudio não estiver lá, o app notarizado grava silêncio na máquina de
# destino — e o pedido de permissão nem aparece. Conferir aqui é barato; descobrir isso
# depois é uma versão distribuída inútil.
codesign -d --verbose=2 "$APP" 2>&1 | grep -q "flags=.*runtime" \
    || { echo "✗ o app não ficou com hardened runtime"; exit 1; }
codesign -d --entitlements - --xml "$APP" 2>/dev/null \
    | grep -q "com.apple.security.device.audio-input" \
    || { echo "✗ falta o entitlement de entrada de áudio"; exit 1; }
echo "  ✓ hardened runtime e entitlement de áudio"

CODESIGN_IDENTITY="$IDENTITY" "$ROOT/scripts/make-dmg.sh"

# MARK: - Notarização

echo
echo "▸ Enviando para a Apple (leva de dois a quinze minutos)"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait

echo
echo "▸ Grampeando o carimbo no DMG"
xcrun stapler staple "$DMG"

# MARK: - A verificação que importa

echo
echo "▸ Conferindo como o Gatekeeper vai ver"
xcrun stapler validate "$DMG"
spctl -a -t open --context context:primary-signature -v "$DMG"

# E o app de dentro, que é o que a pessoa vai abrir. Testamos a cópia montada, não a que
# está em build/: só ela passou pelo DMG, que é o caminho real até a outra máquina.
MOUNT=$(mktemp -d)
hdiutil attach "$DMG" -nobrowse -quiet -mountpoint "$MOUNT"
trap 'hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true' EXIT
spctl -a -t exec -vv "$MOUNT/Capita.app"
echo

echo "✓ DMG notarizado e grampeado: $DMG ($(du -h "$DMG" | cut -f1))"
echo "  Pode ser enviado para outra máquina — o Gatekeeper vai deixar abrir sem internet."
