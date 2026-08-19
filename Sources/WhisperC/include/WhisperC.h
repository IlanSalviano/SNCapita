// Expõe a API C do whisper.cpp ao Swift.
//
// O whisper.cpp é compilado separadamente pelo scripts/build-whisper.sh e instalado em
// vendor/whisper/. Este alvo existe apenas para que o SwiftPM enxergue os cabeçalhos e
// gere o módulo `WhisperC`; o código de verdade vem das bibliotecas estáticas linkadas
// pelo alvo Capita.

#ifndef CAPITA_WHISPER_C_H
#define CAPITA_WHISPER_C_H

#include "whisper.h"

#endif
