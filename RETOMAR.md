# Onde paramos — 19/08/2026

**Fases 0 a 4 entregues**, mais exportação e a correção de um bug de captura que corrompia
gravações em silêncio. Validado em duas reuniões reais, de 54 e de 68 minutos.

```bash
make run     # compila, instala em ~/Applications e abre (ícone na barra de menus)
make stop
make dmg     # instalador (536 MB, tudo embarcado)
```

## O estado do repositório

Tudo vive na branch **`fase-4-e-correcao-de-captura`**, três commits, **sem push**. A `main`
está intocada em `3a13a0b`.

| | |
|---|---|
| `c9771a1` | A taxa de amostragem vem do dispositivo, não do que o tap declara |
| `e8f9be7` | Exportação: levar a reunião para fora do Capita |
| `7ad394b` | Fase 4: a reunião vira ata |

A ordem é captura → exportação → Fase 4 porque nessa ordem nenhum commit depende do
seguinte. **Os três foram verificados com `git checkout` e build limpo**: cada um compila
sozinho, então `git bisect` funciona.

⚠ A identidade do git foi configurada **só neste repositório** (`git config user.name`, sem
`--global`) — não havia nenhuma e o commit falhava.

⚠ O motor de IA está **fixado no Ollama** em `UserDefaults`, de um teste. Para voltar ao
melhor disponível: Ajustes → "Usar o melhor disponível", ou
`defaults delete com.ilansalviano.capita intelligence.preferredProvider`.

---

## O que fazer primeiro na próxima sessão

Dois requisitos novos, ainda **não implementados**. Ver "Próximas fases" ao fim para o
detalhe de cada um.

1. **Título de verdade nas gravações** — hoje a biblioteca mostra "19 Aug 2026 at 12:04".
   Precisa mostrar um título que resuma a conversa, com data/hora e duração ao lado.
2. **Mapa mental gráfico, editável e exportável** — hoje é uma árvore de leitura, estática.

---

## O que a reunião real provou (fases 0–3)

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

---

## Fase 4 — Sumários com IA

Uma chamada só produz tudo: título, resumo executivo, seções temáticas nomeadas pela IA,
decisões com justificativa, action items agrupados por responsável com prazo, mapa mental
e um infográfico. Agrupar não é elegância — o Claude Code tem um piso de ~8k tokens de
overhead por invocação, e quatro perguntas separadas custariam quatro vezes mais.

Medido na reunião de 54 min (46.853 caracteres de diálogo), com Claude Code: **45 a 180 s**
por resumo, JSON válido em todas as execuções.

**Templates** por tipo de reunião (automático, trabalho, 1:1, cliente, técnica, aula)
mudam o que se extrai. O padrão é deixar o modelo deduzir pelo conteúdo.

**Cache** em `summary.json`, chaveado pelo hash do diálogo + template. Isso faz a coisa
certa acontecer sozinha: renomear "S3" para "Amy" muda o texto, muda o hash, e a ata é
refeita com os action items atribuídos a Amy. A interface avisa que o resumo envelheceu em
vez de apagá-lo.

**Reuniões longas** passam por mapa-e-redução: acima de 60 mil caracteres o diálogo é
cortado no fim de uma fala (nunca no meio), cada parte vira anotações e uma chamada final
escreve a ata. Só nesse caso — dividir sempre custaria qualidade em toda reunião normal.

### Identificação de locutores — o que ganhamos sobre o Plaud

A diarização sabe que existem sete pessoas e não sabe o nome de nenhuma. Mas os nomes
estão na conversa: as pessoas se cumprimentam e se interpelam. A IA os extrai e o app
oferece aplicá-los com um clique. O Plaud entrega `Speaker 1 / Speaker 2` e deixa a
digitação por sua conta.

⚠ **Três armadilhas, todas resolvidas em código e não no prompt** — porque a instrução
está lá e o modelo a desobedece assim mesmo:

1. **Ele batiza quem gravou.** Os outros o chamam pelo nome durante a call, e a ata passa
   a atribuir a "Elon" tarefas que são suas. Quem gravou já está identificado por
   construção: é o dono da trilha do microfone.
2. **Ele preenche o que não sabe** — um participante que ninguém chamou pelo nome volta
   como `"Unknown"`.
3. **Ele reusa nomes já atribuídos.** Depois que você nomeia parte dos locutores, os que
   sobram são justamente os que ninguém nomeou, e o modelo os batiza por posição com nomes
   que já pertencem a outra pessoa (`S5 → Elise` quando Elise já era o S6).

⚠ **Aspas retas dentro de strings JSON quebram a resposta inteira.** Aconteceu na primeira
execução: `from "tell us what you built" (policing)`. Não é erro de formato, é erro de
citação, e derruba dezenas de milhares de caracteres por causa de um par de aspas no meio
de um parágrafo. Duas defesas: o prompt pede aspas curvas, e `repairingUnescapedQuotes`
escapa o que passar. **A segunda ainda dispara** com o Claude Code — não a remova.

⚠ **A síntese do `Decodable` do Swift ignora valores padrão.** `var x: [Item] = []` não
salva você: se a chave faltar, o decode inteiro falha. Todos os tipos do `MeetingSummary`
têm `init(from:)` escrito à mão. Uma reunião sem tarefas costuma vir sem `actionItems`.

---

## Exportação

```
Exportar ▾   Áudio + transcrição…      pasta com M4A + Markdown
             Somente o áudio (M4A)…
             Resumo (.md)… / Infográfico (.png)…
             Transcrição › Markdown / SRT / Texto
             Trilhas separadas (WAV)… / Revelar no Finder
```

O caso de uso que motivou: subir a reunião no Plaud ou equivalente e comparar. Os 206 MB
de WAV viram **13,3 MB** de M4A em 1,6 s.

⚠ **O AAC-LC recusa mais de 32 kbps a 16 kHz mono.** `AudioConverterSetProperty` falha com
`kAudioFileUnsupportedDataFormatError` já na criação do arquivo. Para voz a 16 kHz, 32 kbps
é transparente de qualquer forma.

A mixagem faz **duas passagens**: a primeira mede o pico da soma, a segunda escreve com o
ganho certo. Somar as duas trilhas a meio volume nunca satura e entrega um arquivo surdo —
justamente quando a transcrição alheia precisa de sinal.

O SRT usa os cortes crus do Whisper; Markdown e texto usam blocos por locutor. Um bloco
pode durar noventa segundos: ótimo para ler, impossível como legenda.

---

## A taxa de amostragem vem do dispositivo, não do tap

Numa reunião de 68 min com **AirPods Max**, a trilha do sistema saiu com metade da duração
e o áudio no dobro da velocidade. Em chamada, o Bluetooth cai para **24 kHz**. O
`kAudioTapPropertyFormat` declara **48 kHz** e não acompanha. O app acreditava no tap, e
cada quadro passava a valer metade do tempo que vale.

O modo de falha é o pior possível: nada erra. O arquivo existe, as duas trilhas existem, o
medidor de nível funciona, a transcrição roda. Só o resultado é ininteligível.

`captureFormat` agora tira a **forma** do tap (canais, bytes por quadro) e a **taxa do
dispositivo**. E há um ouvinte de `kAudioDevicePropertyNominalSampleRate`, que é a metade
traiçoeira: quando a chamada começa, os AirPods **não trocam de dispositivo** — continuam
sendo a mesma saída padrão, e o ouvinte de troca de dispositivo que já existia não dispara.
Só a taxa muda.

O `TapSpike` agora mede isso: quadros recebidos contra quadros esperados. Dava **0,50×**,
dá **1,00×**. Uma gravação real de 12,7 s produziu as duas trilhas com 0,13 s de diferença.

**Áudio gravado torto é recuperável**, e vale saber como: os quadros estão todos lá, só
rotulados com a taxa errada. Reinterpretar o WAV a 8 kHz (metade dos 16 kHz do cabeçalho)
e reamostrar para 16 kHz devolveu os 4.057 s exatos. A banda fica em ~4 kHz, qualidade de
telefone, porque o filtro anti-alias cortou ali — e o Whisper transcreve isso bem: a
reunião recuperada rendeu 599 segmentos brutos contra 185, e **zero** anotações inventadas
contra 58.

---

## Duas coisas que pareciam bug e não são

Registradas porque custaram uma tarde e vão parecer bug de novo.

**Os timestamps do microfone estão certos.** Parecem comprimidos porque a soma das durações
dos segmentos é quase igual ao intervalo que eles cobrem — o que sugere "fala sem pausas,
logo linha do tempo sem silêncios". Não é: é só o Whisper emitindo segmentos encostados um
no outro. Medido pelo VAD, os tempos batem com o áudio original.

**As anotações inventadas na trilha do microfone são o comportamento correto.** Numa
reunião de 68 min, 377 dos 471 segmentos do microfone foram descartados como
`[SOM DE CHÁ RISADO]` e afins — parece que estamos perdendo 80% da sua fala. Não estamos:
confirmado por escuta, aqueles trechos são ruído de fundo. O VAD deixa o ruído passar, o
Whisper o rotula honestamente como som, e o filtro de anotação o remove. A cadeia inteira
funciona.

O diagnóstico agora é direto — cada trilha loga o que o VAD achou e o que cada filtro comeu:

```
sistema: áudio 4057s | VAD 333 trechos, 3910s de fala (96%) até 4049s | segmentos brutos 599
sistema: filtros — 0 vazios, 0 anotações, 0 ruído
```

⚠ `no_context = true` **não muda nada** aqui. Foi a suspeita óbvia para o laço de
alucinação e foi testada: 377 anotações antes, 377 depois.

---

## Limitação conhecida (fases 0–3)

O corte por locutor só resolve quando a troca cai **dentro** de um segmento do Whisper.
Quando os dois limites quase coincidem mas estão deslocados por uma ou duas palavras, o
erro está na posição da fronteira e o corte não ajuda:

```
[25:33] S2  ...Maybe, maybe you have a whole
[25:37] S1  different approach. I have projects in Claude...
```

⚠ **Não ligue `token_timestamps` do whisper.cpp.** Parece a solução óbvia, mas é
incompatível com o VAD: os tempos passam a vir da linha do tempo comprimida, sem os
silêncios. Na reunião de 54 min as falas se deslocaram em até 5,5 minutos. E desligar o
VAD não é opção — foi ele que garantiu zero alucinação.

---

## Motor de IA

Nada é embarcado. O app detecta o que a máquina já tem, em cascata: **Claude Code** →
**Ollama** (`localhost:11434`) → **LM Studio** (`localhost:1234`). O primeiro disponível
vence; nos Ajustes dá para fixar outro.

⚠ **Detectar o runtime não basta — é preciso escolher um modelo que caiba.** Nesta máquina
o modelo de 30B pede 19,7 GB com 17,3 GB livres e a API responde com erro. O app prefere o
maior modelo abaixo de 45% da memória física.

⚠ **Um app lançado pelo Finder não herda o PATH do shell** — `which claude` não funciona
dentro do app. Os caminhos conhecidos são procurados explicitamente.

**Validado com Ollama** (`gemma4:e4b-mlx`, escolhido sozinho: 8,8 GB cabem no teto de 45%
de 25 GB; o de 30B não). Uma reunião de 68 min, 59.682 caracteres de diálogo, **150 s** e
JSON completo — seções, decisões, action items, mapa mental e infográfico. O reparo de
aspas soltas disparou aqui também; ele não é luxo para o caminho local.

O Ollama 0.32 dimensiona o contexto sozinho: 53 mil caracteres (12.667 tokens) entraram
inteiros num teste com chave plantada no início, e o modelo a recuperou. Não é preciso
passar `num_ctx`.

⚠ **O modelo local é menos consistente entre execuções.** Duas rodadas da mesma reunião
identificaram 5 locutores e 1 locutor. O conteúdo das seções se manteve; a extração
estruturada oscila.

⚠ **Ele confunde o campo do selo com o do ícone** e escreve "task", "money", "warning" no
`badge`. Instrução no prompt não resolveu sozinha — há uma guarda em `sanitize` que limpa
selos que sejam nome de ícone.

---

## Defeito conhecido, não corrigido

**O app aborta ao encerrar**, num assert do ggml/Metal
(`ggml_metal_device_free` durante `exit`, via `__cxa_finalize_ranges`). Acontece depois de
tudo funcionar, então não perde dado — mas todo encerramento gera um crash log. Vem do
whisper.cpp vendorizado; a ordem de destruição do backend Metal na saída do processo.

---

## Decisão em aberto

**Notarização.** Você vai providenciar a conta Apple Developer. Sem ela o DMG não abre em
outra máquina: o macOS 26 só oferece "Mover para o Lixo".

---

## Próximas fases

### Fase 5 — Título de verdade nas gravações

Hoje a biblioteca lista "19 Aug 2026 at 12:04". Isso identifica *quando*, não *o quê* — e
com trinta reuniões na lista, achar aquela sobre a arquitetura da Caixa vira uma caçada.

O título precisa resumir a conversa, com **data/hora e duração ao lado**, não no lugar.

O que já existe: `MeetingSummary.title` é exatamente isso, gerado e bom
("Aligning on AI Tools for Enterprise Accounts", "Governança e Estratégia de Serviços
Digitais em Plataforma"). O trabalho é levá-lo para `Recording.title` e para a lista.

Pontos que decidem o desenho:

- **Não esperar o resumo.** O resumo é sob demanda e custa minutos; o título precisa estar
  lá assim que a transcrição termina. Uma chamada curta e barata só para o título, logo
  depois de transcrever, resolve — e quando o resumo completo chegar, ele substitui.
- **Nunca sobrescrever um título que o usuário digitou.** Precisa de um campo em
  `metadata.json` dizendo a origem (gerado × manual), no mesmo espírito de
  `speakerNames`: o palpite da IA cede sempre para a escolha da pessoa.
- **Sem motor de IA disponível, cair no formato atual** — data e hora. Um app que mostra
  gravações sem nome porque o Ollama não estava rodando é pior que um app sem a feature.
- Renomear pela lista (duplo clique) deve continuar possível.

### Fase 6 — Mapa mental gráfico, editável e exportável

Hoje o mapa mental é uma árvore de leitura com trilhos verticais: correta, mas estática. O
que se quer é enxergar a reunião espacialmente, **mexer nela** — corrigir um ramo, acrescentar
o que a IA não pegou, reorganizar — e depois **exportar a imagem**.

O que já existe: `MeetingSummary.MindNode` (rótulo + filhos, três níveis), o `MindMapView`
com o layout achatado, e o caminho de exportação de imagem via `ImageRenderer` já provado
em `SummaryExporter.writePNG` (196 KB, 2× de escala, legível).

Pontos que decidem o desenho:

- **A edição não pode morrer quando o resumo é regerado.** É a mesma tensão dos nomes de
  locutor, e a resposta deve ser a mesma: o trabalho da pessoa ganha da IA. Guardar o mapa
  editado num arquivo próprio (`mindmap.json`), separado do `summary.json`, e ao regerar
  oferecer a fusão em vez de aplicá-la — nunca descartar em silêncio.
- **Layout em árvore de verdade**, não recuo. Reingold–Tilford é o algoritmo padrão para
  isso e cabe em pouca coisa; o difícil é o gesto, não a matemática.
- ⚠ **Uma `View` do SwiftUI não pode se conter** — o tipo opaco do `body` ficaria definido
  em termos de si mesmo e o compilador recusa. Foi o que obrigou o `MindMapView` atual a
  achatar a árvore em linhas. Um mapa 2D provavelmente quer o mesmo: calcular as posições
  de todos os nós antes de desenhar, e renderizar uma lista plana de nós posicionados mais
  as arestas num `Canvas`.
- Precisa de pan/zoom, seleção, criar/editar/apagar nó e arrastar para outro pai.
- Exportar deve renderizar o mapa **inteiro** na sua extensão natural, não o que está
  visível na janela — mesma armadilha da largura fixa de 900 pt no infográfico.

### Depois

- **Ask AI (RAG)**: busca semântica com citações que saltam para o timestamp. Direção
  pesquisada: llama.cpp compartilhando o mesmo checkout do ggml + `embeddinggemma-300m`.
- **Detecção de reunião, notas, screenshots durante a call.**
- **Busca global e atalhos.** (A exportação já saiu, junto com a Fase 4.)

Plano completo em `~/.claude/plans/indexed-puzzling-kahan.md`.

---

## Diagnóstico

```bash
Capita --smoke-record 8              # grava e valida as duas trilhas
Capita --smoke-transcribe [id]       # transcreve; sem id usa a mais recente
Capita --smoke-engines               # detecta e testa o motor de IA
Capita --smoke-summarize [id]        # mostra a ata salva; --force regera
Capita --smoke-export [id]           # mixa e exporta tudo para /tmp, com conferência
Capita --open-library                # abre a biblioteca direto
log stream --predicate 'subsystem == "com.ilansalviano.capita"'
```

O `--smoke-export` não se contenta com "o arquivo existe": ele mede a energia do mix num
trecho em que só você fala e noutro em que só os outros falam. Um M4A com o tamanho e a
duração certos ainda pode ter perdido uma trilha — foi assim que a gravação quebrou quando
o fone era plugado no meio, e o sintoma era nenhum.

O `--smoke-transcribe <prefixo-do-id>` re-transcreve uma gravação antiga. Use para checar
regressão: os filtros anti-alucinação já foram recalibrados várias vezes, e cada ajuste
arrisca reabrir um problema anterior.
