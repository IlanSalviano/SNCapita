#!/bin/bash
# Compila o whisper.cpp como bibliotecas estáticas e as instala em vendor/.
#
# Estático, e não dinâmico, porque o app precisa ser autocontido: o .dmg vai rodar numa
# máquina onde ninguém pode instalar dependências nem tem privilégio de administrador.
# Tudo que o Capita precisa para transcrever vai dentro do binário.
#
# Roda uma vez; depois disso o vendor/ fica em cache e o `swift build` é instantâneo.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
VENDOR="$ROOT/vendor/whisper"
WHISPER_VERSION="${WHISPER_VERSION:-master}"

# Precisa casar com `platforms:` no Package.swift e com LSMinimumSystemVersion no
# make-app.sh. Sem fixar isto, o cmake usa a versão do macOS de quem compila, e o
# linker avisa que os objetos exigem um sistema mais novo do que o app declara suportar
# — o que viraria uma falha na máquina de quem recebesse o .dmg.
DEPLOYMENT_TARGET="15.0"

if [ -f "$VENDOR/lib/libwhisper.a" ] && [ "${FORCE:-0}" != "1" ]; then
    echo "✓ whisper.cpp já compilado em vendor/. Use FORCE=1 para recompilar."
    exit 0
fi

command -v cmake >/dev/null || {
    echo "✗ cmake não encontrado. Instale com: brew install cmake"
    exit 1
}

WORK="$ROOT/.build/whisper-src"
if [ ! -d "$WORK/.git" ]; then
    echo "▸ Baixando whisper.cpp"
    rm -rf "$WORK"
    git clone -q --depth 1 --branch "$WHISPER_VERSION" \
        https://github.com/ggml-org/whisper.cpp "$WORK"
fi

echo "▸ Compilando (arm64, Metal)"
cmake -S "$WORK" -B "$WORK/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    -DBUILD_SHARED_LIBS=OFF \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DWHISPER_BUILD_EXAMPLES=OFF \
    -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_BUILD_SERVER=OFF \
    > /dev/null

cmake --build "$WORK/build" -j"$(sysctl -n hw.ncpu)" --target whisper > /dev/null

echo "▸ Instalando em vendor/whisper"
rm -rf "$VENDOR"
mkdir -p "$VENDOR/lib" "$VENDOR/include"

# GGML_METAL_EMBED_LIBRARY compila os shaders Metal DENTRO da biblioteca. Isso não é
# conveniência: as Command Line Tools não trazem o compilador `metal`, então shaders
# soltos seriam impossíveis de compilar aqui — e um .metallib externo teria de ser
# copiado para o bundle e encontrado em runtime.
find "$WORK/build" -name "*.a" -exec cp {} "$VENDOR/lib/" \;

cp "$WORK/include/whisper.h" "$VENDOR/include/"
cp "$WORK/ggml/include/"*.h "$VENDOR/include/"

# Os cabeçalhos também vão para dentro do alvo WhisperC.
#
# Um `headerSearchPath` apontando para vendor/ não basta: o SwiftPM usa esses caminhos ao
# compilar o C do alvo, mas não ao construir o módulo Clang que o Swift importa — o
# `import WhisperC` falharia com "whisper.h file not found". Com os cabeçalhos entre os
# públicos do alvo, os dois caminhos funcionam.
echo "▸ Instalando cabeçalhos em Sources/WhisperC/include"
cp "$VENDOR/include/"*.h "$ROOT/Sources/WhisperC/include/"

echo "▸ Bibliotecas instaladas:"
ls -1sh "$VENDOR/lib" | tail -n +2 | sed 's/^/    /'
