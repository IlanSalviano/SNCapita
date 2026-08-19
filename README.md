# Capita

Gravador e transcritor de reuniões para macOS. Captura o áudio de Teams, Zoom, Meet ou
qualquer chamada — **sem bot entrando na reunião** — e transcreve localmente.

Nada sai da sua máquina: a transcrição roda no próprio computador, com o modelo embarcado
no app.

---

## Restrições que moldaram o projeto

Não é um clone genérico do Plaud Desktop; três restrições ditaram quase toda a arquitetura:

| Restrição | Consequência |
|---|---|
| **Sem privilégios de administrador** | Nada de driver de áudio virtual. Usamos CoreAudio process taps, cujo serviço TCC (`AudioCapture`) não é admin-gated — ao contrário da "Gravação de Tela" que o ScreenCaptureKit exigiria. |
| **Sem Docker, Python ou pré-requisitos** | whisper.cpp compilado estaticamente dentro do binário; modelos embarcados no `.app`. |
| **Distribuível por `.dmg`** | Tudo autocontido: o app roda em outra máquina Apple Silicon sem instalar nada. |

## Como a captura funciona

| Quem fala | Por onde passa | Como capturamos |
|---|---|---|
| Os outros participantes | Saída de áudio do sistema | CoreAudio process tap |
| Você | Microfone | `AVAudioEngine` |

As duas trilhas são gravadas **separadamente** e mixadas só na reprodução. Isso resolve de
graça a metade difícil da diarização: o que entrou pelo microfone é você, o que saiu pelos
alto-falantes são os outros. Funciona com fones, porque o tap intercepta o áudio antes do
dispositivo de saída.

Capturamos o sistema inteiro, não só o app da reunião: um Teams ou Meet aberto no
navegador emite áudio como Chrome, e filtrar por aplicativo perderia a reunião inteira.

---

## Como rodar

```bash
./scripts/build-whisper.sh    # uma vez: compila o whisper.cpp (precisa de cmake)
./scripts/fetch-model.sh      # uma vez: baixa o modelo de transcrição (~530MB)
make signing-cert             # uma vez: certificado estável (evita re-pedir permissões)
make run                      # compila, instala em ~/Applications e abre
```

O app aparece na **barra de menus**, não no Dock.

### Comandos

| Comando | O que faz |
|---|---|
| `make run` | Compila, instala e abre |
| `make dmg` | Gera o `.dmg` distribuível |
| `make check` | Verifica assinatura, plist e recursos do bundle |
| `make spike-tap` | Prova que a captura de áudio funciona sem admin |
| `make smoke-record` | Grava 8s de verdade e confere as duas trilhas |
| `make stop` | Encerra o app |

### Diagnóstico

```bash
Capita --smoke-record 8     # grava e valida as trilhas
Capita --smoke-transcribe   # transcreve a gravação mais recente e imprime
Capita --smoke-engines      # detecta e testa o motor de IA
Capita --smoke-summarize    # resume e imprime a ata inteira (--force regera)
Capita --smoke-export       # mixa, exporta tudo para /tmp e confere
Capita --open-library       # abre a biblioteca direto
log stream --predicate 'subsystem == "com.ilansalviano.capita"'
```

O `--smoke-summarize` só regera com `--force`: resumir uma reunião longa leva minutos e,
no Claude Code, custa dinheiro. Sem a flag ele mostra o resumo salvo e diz se ainda
corresponde ao transcript atual.

---

## Onde ficam os dados

```
~/Library/Application Support/Capita/
├── Recordings/<uuid>/
│   ├── system.wav        os outros participantes (16 kHz mono)
│   ├── mic.wav           você
│   ├── metadata.json
│   ├── transcript.json
│   └── summary.json      a ata gerada pela IA, em cache
└── Models/               modelos baixados (têm precedência sobre o embarcado)
```

16 kHz mono não é escolha estética: é o formato que o Whisper consome. Gravar já nele
evita uma reamostragem e reduz o arquivo em ~12× contra estéreo 48 kHz.

---

## Qualidade da transcrição

O Whisper **inventa frases plausíveis** quando recebe silêncio ou ruído — e uma reunião
tem muito dos dois. Numa ata, texto fabricado é o pior tipo de erro: o leitor não tem como
saber que é falso. Há três camadas de defesa, em ordem de atuação:

1. **VAD (Silero)** recorta só os trechos com fala antes de transcrever. Limiar por
   trilha: o áudio do sistema vem de um tap digital e é silêncio absoluto fora da fala; o
   microfone carrega ruído de sala o tempo todo.
2. **Limiares do modelo** (`no_speech_thold`, entropia, logprob) descartam decodificações
   degeneradas.
3. **Porta de ruído** compara a **mediana** de energia do segmento com o nível de fala da
   própria trilha. Medido em gravação real: fala legítima fica em 0,64–0,71; ruído, em
   0,22. O corte está em 0,30.

O critério é relativo à própria gravação, não absoluto — funciona igual para quem fala
alto ou baixo, com microfone bom ou ruim.

---

## Notas de build

Compilado **sem o Xcode.app**, só com as Command Line Tools. Isso impõe algumas escolhas
que parecem estranhas fora de contexto:

- **Sem `.xcassets`** — o `actool` que os compila exige o Xcode completo. O ícone é um
  `.icns` gerado por `scripts/make-icon.swift` com o `iconutil`, que é um binário real.
- **Sem String Catalogs** — o `xcstringstool` também só vem com o Xcode. Localização no
  formato clássico `.lproj/Localizable.strings`.
- **Sem `resources:` no SwiftPM** — o `Bundle.module` gerado aponta para a raiz do `.app`,
  o que viola o formato e faz o `codesign` falhar. Recursos são copiados para
  `Contents/Resources` pelo `make-app.sh` e lidos via `Bundle.main`.
- **Sem shaders `.metal` próprios** — não há compilador `metal` nas CLT. O ggml resolve
  isso com `GGML_METAL_EMBED_LIBRARY`, que embute o metallib no binário.

### Assinatura

`make signing-cert` cria um certificado self-signed no keychain de **login** (pede sua
senha, não a de administrador). Isso importa mais do que parece: com assinatura ad-hoc o
Designated Requirement degenera para igualdade de cdhash, e o macOS trata cada build como
um app diferente — re-pedindo a permissão de áudio toda vez.

```bash
codesign -d --requirements - build/Capita.app
# bom:  designated => identifier "..." and certificate leaf = H"..."
# ruim: designated => cdhash H"..."
```

Para **distribuir** é preciso Developer ID + notarização (conta Apple Developer, US$99/ano,
não exige admin da máquina). No macOS 26, um app não notarizado que chega por `.dmg` só
oferece "Mover para o Lixo" — o antigo bypass de Control-clique foi removido.

```bash
export CODESIGN_IDENTITY="Developer ID Application: ..."
make dmg
xcrun notarytool submit build/Capita.dmg --keychain-profile <perfil> --wait
xcrun stapler staple build/Capita.dmg
```
