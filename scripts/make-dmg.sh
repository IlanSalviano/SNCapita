#!/bin/bash
# Empacota Capita.app num .dmg distribuível.
#
# O DMG aponta para ~/Applications, não /Applications: instalar na pasta do sistema
# exige senha de administrador, e o projeto inteiro parte da premissa de que o usuário
# não tem esse privilégio.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

APP_NAME="Capita"
APP="$ROOT/build/$APP_NAME.app"
DMG="$ROOT/build/$APP_NAME.dmg"

[ -d "$APP" ] || { echo "✗ $APP não existe. Rode ./scripts/make-app.sh antes."; exit 1; }

STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT

echo "▸ Preparando conteúdo"
cp -R "$APP" "$STAGING/"

# Deliberadamente SEM o atalho "Applications" que os DMGs costumam trazer.
#
# Um symlink grava o caminho no momento da criação: `ln -s ~/Applications` viraria
# /Users/ilan.salviano/Applications e apontaria para o nada na máquina de outra pessoa.
# E não existe symlink portátil para "o home do usuário atual". A alternativa óbvia,
# apontar para /Applications, exigiria senha de administrador para instalar — que é
# exatamente a restrição que este projeto contorna. Então instruímos pelo LEIA-ME.

cat > "$STAGING/LEIA-ME.txt" <<'README'
Capita — instalação
===================

1. Abra a SUA pasta de aplicativos:
   no Finder, menu "Ir" > "Início" (ou Shift-Cmd-H), e entre em "Applications".
   Se ela não existir, crie uma pasta com esse nome exato.

   Arraste o Capita.app para lá.

   Use essa pasta, e não a /Applications do sistema: instalar na do sistema
   exige senha de administrador, e o Capita foi feito para não precisar de uma.

2. Abra o Capita. Ele aparece na BARRA DE MENUS, no topo da tela — não no Dock.

3. Na primeira gravação o macOS vai pedir duas permissões:
     • Microfone            — para gravar a sua voz
     • Gravação de Áudio    — para gravar os outros participantes
   Nenhuma delas exige senha de administrador.

Todo o processamento é local. Nenhum áudio sai do seu computador.
README

echo "▸ Gerando o DMG"
rm -f "$DMG"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    "$DMG" >/dev/null

SIZE=$(du -h "$DMG" | cut -f1)
echo "▸ Pronto: $DMG ($SIZE)"

# Um DMG não assinado herda quarentena ao ser transferido, e o macOS 26 se recusa a abrir
# o app — só oferece "Mover para o Lixo". Notarizar é obrigatório para distribuir.
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    echo "▸ Assinando o DMG com $CODESIGN_IDENTITY"
    codesign --force --sign "$CODESIGN_IDENTITY" "$DMG"
    echo "  Próximo passo para distribuir:"
    echo "    xcrun notarytool submit \"$DMG\" --keychain-profile <perfil> --wait"
    echo "    xcrun stapler staple \"$DMG\""
else
    echo
    echo "⚠ DMG NÃO notarizado. Serve para testar nesta máquina, mas noutra o macOS vai"
    echo "  recusar abrir o app (só oferece 'Mover para o Lixo'). Para distribuir de"
    echo "  verdade, exporte CODESIGN_IDENTITY com um Developer ID e notarize."
fi
