#!/bin/bash
# Monta Capita.app à mão, sem Xcode.app.
#
# O SwiftPM produz um executável solto; um app de barra de menus precisa de um bundle de
# verdade (Info.plist, ícone, .lproj). Montar na mão também nos dá controle sobre a
# assinatura, que é o que mantém a permissão de captura de áudio estável entre builds.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

APP_NAME="Capita"
BUNDLE_ID="com.ilansalviano.capita"
VERSION="0.1.0"
BUILD="1"
MIN_MACOS="15.0"

APP="$ROOT/build/$APP_NAME.app"
CONTENTS="$APP/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "▸ Compilando (release, arm64)"
swift build -c release --product "$APP_NAME"

echo "▸ Montando o bundle"
rm -rf "$APP"
mkdir -p "$MACOS_DIR" "$RESOURCES"

cp "$ROOT/.build/release/$APP_NAME" "$MACOS_DIR/$APP_NAME"

# Recursos vão para Contents/Resources e são lidos por Bundle.main.
# Não usamos `resources:` do SwiftPM: o Bundle.module resultante fica na raiz do .app,
# viola o formato e faz o codesign falhar com "unsealed contents in the root directory".
[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$RESOURCES/"
for lproj in "$ROOT"/Resources/*.lproj; do
    [ -d "$lproj" ] && cp -R "$lproj" "$RESOURCES/"
done

# Modelos embarcados: o de transcrição (~514MB) e o de detecção de fala (~864KB).
# Baixados por scripts/fetch-model.sh; copiamos os que estiverem presentes.
for model in "$ROOT"/Resources/Models/*.bin; do
    [ -f "$model" ] || continue
    echo "▸ Embarcando $(basename "$model") ($(du -h "$model" | cut -f1))"
    cp "$model" "$RESOURCES/"
done

echo "▸ Gerando Info.plist"
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                  <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>           <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>            <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>            <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleShortVersionString</key>    <string>$VERSION</string>
    <key>CFBundleVersion</key>               <string>$BUILD</string>
    <key>CFBundleIconFile</key>              <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>        <string>$MIN_MACOS</string>

    <!-- Agente de barra de menus: sem ícone no Dock, sem janela principal. -->
    <key>LSUIElement</key>                   <true/>

    <!-- Localização. O sistema escolhe pelo idioma preferido do usuário. -->
    <key>CFBundleDevelopmentRegion</key>     <string>pt-BR</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>pt-BR</string>
        <string>en</string>
    </array>

    <!-- Permissões. NSAudioCaptureUsageDescription cobre o CoreAudio process tap, que
         usa o serviço TCC "AudioCapture" — distinto de "ScreenCapture" e, ao contrário
         dele, NÃO exige privilégios de administrador. Sem estas chaves o app é
         encerrado pelo sistema ao tentar capturar. -->
    <key>NSAudioCaptureUsageDescription</key>
    <string>O Capita grava o áudio das suas reuniões para transcrever localmente. Nenhum áudio sai do seu computador.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>O Capita grava a sua voz para incluí-la na transcrição da reunião. Nenhum áudio sai do seu computador.</string>
</dict>
</plist>
PLIST

plutil -lint "$CONTENTS/Info.plist" > /dev/null

echo "▸ Assinando"
# Ordem de preferência da identidade de assinatura:
#   1. CODESIGN_IDENTITY do ambiente (Developer ID, quando a conta Apple sair)
#   2. Um certificado self-signed no keychain de login
#   3. Ad-hoc, como último recurso
#
# Isto importa mais do que parece: com ad-hoc, o Designated Requirement degenera para
# igualdade de cdhash e o macOS trata cada build como um app diferente, re-pedindo a
# permissão de captura de áudio toda vez. Um certificado nomeado ancora o DR e a
# permissão persiste entre builds.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -oE '"[^"]*Capita[^"]*"' | head -1 | tr -d '"') || true
fi

if [ -n "$IDENTITY" ]; then
    echo "  identidade: $IDENTITY"
    codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
else
    echo "  identidade: ad-hoc (a permissão de áudio será re-pedida a cada build —"
    echo "              rode 'make signing-cert' para criar um certificado estável)"
    codesign --force --sign - "$APP"
fi

codesign --verify --strict "$APP"

echo "▸ Pronto: $APP"
echo "  Designated Requirement:"
codesign -d --requirements - "$APP" 2>&1 | sed 's/^/    /' || true
