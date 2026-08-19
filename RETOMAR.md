# Onde paramos — 19/08/2026

**Fases 0 a 3 entregues e validadas numa reunião real de 54 minutos.**

```bash
make run     # compila, instala em ~/Applications e abre (ícone na barra de menus)
make stop
make dmg     # instalador (536 MB, tudo embarcado)
```

---

## O que a reunião real provou

Gravação de 53,6 min, 8.662 palavras, 7 participantes detectados.

| Verificação | Resultado |
|---|---|
| **Separação você × outros** | **0% de vazamento** — 0 de 69 falas suas duplicam a trilha do sistema |
| Segmentos: sistema / microfone | 436 / 69 |
| Sincronia das trilhas em 54 min | 0,6 s de diferença |
| **Alucinação** | **zero** — nenhum marcador do Whisper, nenhuma frase repetida |
| 40+ min em que você não falou | não produziram nenhum texto fabricado |
| Permissões | nenhuma pediu senha de administrador |

A separação é a tese central do produto: o que entra pelo microfone é você, o que sai pela
saída de áudio são os outros. Com fone, funciona.

A diarização se comportou bem com vozes humanas — muito melhor que com as vozes sintéticas
do `say`, que tinham sugerido o contrário. Um participante que falou uma vez só foi
corretamente isolado: o contexto confirma (*"you're on mute. Sorry about that."*).

---

## Correções feitas nesta rodada

**Alinhamento das fronteiras de locutor.** O Whisper corta os segmentos sem saber quem
fala, então um segmento atravessava a troca e a frase inteira ia para uma pessoa só —
51 dos 436 segmentos. Agora o segmento é cortado no ponto da troca.

**Sobreviver à troca de rota de áudio.** Plugar um fone reconfigurava o `AVAudioEngine` e
invalidava o aggregate device: a gravação parava de crescer, em silêncio. Numa gravação
anterior a trilha do microfone terminou em 13 s contra 27 s do sistema.

**Filtro que apagava participantes.** O `NoiseGate` comparava cada trecho com o
participante mais alto da trilha e descartava quem falava mais baixo. Agora compara com o
**piso de ruído**, tratando todos igualmente.

---

## Limitação conhecida

O corte por locutor só resolve quando a troca cai **dentro** de um segmento do Whisper.
Quando os dois limites quase coincidem mas estão deslocados por uma ou duas palavras, o
erro está na posição da fronteira, não na segmentação — e o corte não ajuda. Exemplo que
permanece errado:

```
[25:33] S2  ...Maybe, maybe you have a whole
[25:37] S1  different approach. I have projects in Claude...
```

O *"different approach"* é do S2. Resolver isso exigiria alinhar as fronteiras da
diarização às do Whisper, ou timestamps por palavra confiáveis (ver armadilha abaixo).

⚠ **Não ligue `token_timestamps` do whisper.cpp.** Parece a solução óbvia, mas é
incompatível com o VAD: os tempos dos segmentos passam a vir da linha do tempo comprimida,
sem os silêncios. Na reunião de 54 min as falas se deslocaram em até 5,5 minutos. E
desligar o VAD não é opção — foi ele que garantiu zero alucinação.

---

## Decisões em aberto

**1. Motor de IA para os sumários — bloqueia a Fase 4.**
O Claude Code CLI não pode ser embarcado no `.dmg`: depende da sua conta e autenticação.

| Opção | Custo | Consequência |
|---|---|---|
| LLM local via llama.cpp | +2–4 GB no DMG | Atende "tudo embarcado"; qualidade abaixo do Claude |
| Detectar `claude` e usar se existir | zero | Qualidade máxima na sua máquina, nada na dos outros |
| Campo para chave de API | zero | Portátil, mas cada usuário precisa de chave paga |

**2. Notarização.** Você vai providenciar a conta Apple Developer. Sem ela o DMG não abre
em outra máquina: o macOS 26 só oferece "Mover para o Lixo".

---

## Próximas fases

- **Fase 4 — Sumários com IA**: templates por tipo de reunião, action items, decisões.
  Depende da decisão 1.
- **Fase 5 — Ask AI (RAG)**: busca semântica com citações que saltam para o timestamp.
  Direção pesquisada: llama.cpp compartilhando o mesmo checkout do ggml + `embeddinggemma-300m`.
- **Fase 6 — Detecção de reunião, notas, screenshots durante a call.**
- **Fase 7 — Exportação, busca global, atalhos.**

Plano completo em `~/.claude/plans/indexed-puzzling-kahan.md`.

---

## Diagnóstico

```bash
Capita --smoke-record 8              # grava e valida as duas trilhas
Capita --smoke-transcribe [id]       # transcreve; sem id usa a mais recente
Capita --open-library                # abre a biblioteca direto
log stream --predicate 'subsystem == "com.ilansalviano.capita"'
```

O `--smoke-transcribe <prefixo-do-id>` re-transcreve uma gravação antiga. Use para checar
regressão: os filtros anti-alucinação já foram recalibrados várias vezes, e cada ajuste
arrisca reabrir um problema anterior.
