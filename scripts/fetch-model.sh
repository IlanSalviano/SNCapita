#!/bin/bash
# Baixa o modelo de transcrição que será embarcado no .app.
#
# Fica fora do repositório (são ~540MB) e é copiado para Contents/Resources pelo
# make-app.sh. Embarcar, em vez de baixar no primeiro uso, é o que permite ao app
# transcrever offline desde o primeiro segundo na máquina de quem receber o .dmg.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

MODEL="${1:-ggml-medium-q5_0.bin}"
DEST="$ROOT/Resources/Models/$MODEL"
URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$MODEL"

if [ -f "$DEST" ]; then
    echo "✓ $MODEL já existe ($(du -h "$DEST" | cut -f1))"
    exit 0
fi

mkdir -p "$(dirname "$DEST")"
echo "▸ Baixando $MODEL (~540MB)"

# Para num arquivo .partial e só move no fim: um download interrompido não pode virar um
# modelo truncado que o whisper tentaria carregar.
curl -fL --progress-bar "$URL" -o "$DEST.partial"
mv "$DEST.partial" "$DEST"

echo "✓ Pronto: $DEST ($(du -h "$DEST" | cut -f1))"
