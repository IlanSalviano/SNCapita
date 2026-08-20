# Onde paramos — 20/08/2026

**Fases 0 a 6 entregues**, mais exportação, a correção de um bug de captura que corrompia
gravações em silêncio e o fim do abort ao encerrar. Validado em duas reuniões reais, de 54
e de 68 minutos.

```bash
make run     # compila, instala em ~/Applications e abre (ícone na barra de menus)
make stop
make dmg     # instalador (536 MB, tudo embarcado)
```

## O estado do repositório

Tudo vive na branch **`fase-4-e-correcao-de-captura`**, **sem push**. A `main` está
intocada em `3a13a0b`.

| | |
|---|---|
| `c9771a1` | A taxa de amostragem vem do dispositivo, não do que o tap declara |
| `e8f9be7` | Exportação: levar a reunião para fora do Capita |
| `7ad394b` | Fase 4: a reunião vira ata |
| `7ba78f4` | Sair sem acordar o assert do ggml |
| `8e9aada` | Fase 5: a gravação ganha nome |
| `c2e685a` | Retomar a transcrição interrompida na abertura |
| `29485fd` | Fase 6: o mapa mental vira mapa |

A ordem dos três primeiros é captura → exportação → Fase 4 porque nessa ordem nenhum
commit depende do seguinte. **Foram verificados com `git checkout` e build limpo**: cada
um compila sozinho, então `git bisect` funciona.

⚠ A identidade do git foi configurada **só neste repositório** (`git config user.name`, sem
`--global`) — não havia nenhuma e o commit falhava.

O motor de IA não está mais fixado no Ollama: a preferência foi apagada e a cascata volta
a escolher sozinha (nesta máquina, o Claude Code). Para fixar de novo, Ajustes; para
soltar, `defaults delete com.ilansalviano.capita intelligence.preferredProvider`.

---

## O que fazer primeiro na próxima sessão

O mapa mental foi conferido na tela e funciona, gestos inclusive.
`Capita --open-summary <prefixo-do-id>` abre a biblioteca já na ata, para a próxima vez.

Duas pontas soltas pequenas:

1. **O título do resumo só é aplicado quando o resumo é salvo**, então reuniões resumidas
   antes da Fase 5 continuam com o título curto até serem regeradas.
2. **Um ramo renomeado volta duplicado na fusão do mapa mental** — ver Fase 6.

Depois disso, o que sobrou do plano: Ask AI (RAG), detecção de reunião com notas e
screenshots durante a call, e busca global.

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

## Fase 5 — Título de verdade nas gravações

A lista mostrava "19 Aug 2026 at 12:04": diz *quando*, não *o quê*. Agora a primeira linha
é o assunto e a segunda traz data, hora e duração — ao lado, não no lugar.

Dois títulos chegam em momentos diferentes, e é de propósito:

1. **Logo após a transcrição**, uma chamada curta só para o título (`RecordingTitler`).
   Texto puro, não JSON: é um valor só, e JSON aqui só acrescentaria modo de falha. Medido
   com Claude Code: **15 a 32 s**.
2. **Quando o resumo completo é salvo**, o `MeetingSummary.title` substitui — ele leu a
   reunião inteira, a chamada curta viu o começo.

A chamada curta recebe os primeiros 5.000 caracteres e, se a reunião for longa, mais 3.000
do meio. O começo às vezes é só saudação e espera pelos atrasados, e um título tirado dali
batizaria a reunião de "boas-vindas".

**A origem do título vive no `metadata.json`**, em `titleSource`: `timestamp`, `generated`
ou `manual`. A precedência é a mesma dos nomes de participante — o palpite da IA cede
sempre para a escolha da pessoa, e `RecordingStore.updateTitle` recusa sozinho a
sobrescrita, de modo que nenhum caminho (nem os smoke tests) precisa lembrar da regra.
`updateTitle` também relê o disco antes de salvar: entre a lista carregada e a resposta da
IA passam-se minutos, e nesse intervalo o usuário pode ter digitado.

Renomear é duplo clique na lista, ou o menu de contexto — que também tem "Usar data e
hora" para desfazer um título e voltar ao carimbo.

⚠ **A síntese do `Decodable` não usa valores padrão** — a mesma armadilha do
`MeetingSummary`, agora no `Recording`: um `metadata.json` gravado antes desta fase não tem
`titleSource`, e o decode inteiro falharia. A gravação sumiria da biblioteca. Por isso o
`init(from:)` escrito à mão, com `decodeIfPresent`.

⚠ **Os smoke tests não geram título** (`SmokeTest.suppressesAutoTitle`). O
`--smoke-transcribe` re-transcreve gravações antigas para checar regressão, e cada execução
acordaria o motor para renomear o que já tem nome — no Claude Code, dinheiro. `--title`
liga de volta, de propósito.

Sem motor de IA, nada disso acontece e a gravação continua em data e hora. Verificado:
transcript vazio → `título não gerado: A transcrição é curta demais` → a linha continua
`[timestamp]`.

Verificado nas duas reuniões reais:

| Reunião | Título gerado |
|---|---|
| 68 min, pt | Embarque de processos CAIXA com CSM ou aplicações |
| 54 min, en | Organizing distributed tools and preventing AI skill duplication |

O idioma segue a reunião, não a interface. E a corrente inteira — transcrever → avisar o
`AppState` → chamar a IA → salvar — foi verificada de ponta a ponta com
`--smoke-transcribe <id> --title`.

---

## Fase 6 — Mapa mental gráfico, editável e exportável

A árvore de leitura com trilhos estava correta e era inútil para o que se faz com um mapa
mental — mexer nele. Agora é um mapa 2D: pan, zoom, seleção, criar, renomear, apagar e
arrastar um nó para cima de outro para mudar de pai. Toda edição vai para `mindmap.json`
na hora; não há botão de salvar, que só criaria a chance de perder trabalho ao fechar.

**`mindmap.json` é separado do `summary.json`** pelo mesmo motivo dos nomes de
participante: os dois têm donos diferentes. O resumo é da IA e é refeito sozinho quando o
diálogo muda; o mapa, depois da primeira edição, é da pessoa. Cada nó tem `UUID` próprio —
o rótulo não serve de chave, porque renomear um nó não pode fazer dele outro nó.

**Quando o resumo é refeito e traz um mapa diferente**, o app não escolhe por você. Se o
mapa nunca foi editado, adota o novo em silêncio (não há o que preservar). Se foi editado,
aparece um aviso com três saídas: **trazer o que falta** — a única que não perde nada —,
usar o mapa novo, ou manter o seu. As duas que perdem ficam num menu, não a um clique.

A fusão compara **rótulos**: traz os ramos cujo nome não existe em lugar nenhum do mapa
editado. Um diff de árvore de verdade teria de casar nós renomeados e movidos, e erraria em
silêncio. ⚠ O efeito colateral conhecido: um ramo que você **renomeou** parece novo para a
fusão e volta duplicado — visível, e apagável com Delete. O caso oposto está garantido por
teste: fundir um mapa idêntico não duplica nada.

### O layout

`MindMapLayout` calcula as posições de todos os nós **antes** de desenhar, e a view vira
uma lista plana de nós posicionados mais as arestas num `Canvas`. Não é escolha de estilo:
⚠ **uma `View` do SwiftUI não pode se conter** — o tipo opaco do `body` ficaria definido em
termos de si mesmo. Foi o que obrigou o mapa antigo a achatar a árvore em linhas.

É a variante simples do Reingold–Tilford: cada subárvore ocupa uma faixa vertical própria e
o pai fica centrado entre o primeiro e o último filho. Os contornos da versão completa
servem para *encaixar* subárvores vizinhas — densidade, que é o oposto do que um mapa que
se lê e se edita precisa.

O tamanho de cada nó vem do texto, medido com `NSAttributedString.boundingRect` na mesma
fonte que a view usa. AppKit no meio de SwiftUI é deliberado: é a única forma de saber o
tamanho do texto antes de desenhar, e sem isso não há layout.

⚠ **As ligações saem da borda do nó, não da coluna.** Sair da coluna alinha os pontos de
partida e deixa a linha visivelmente solta em qualquer nó mais estreito que a coluna — foi
o que a primeira imagem exportada mostrou.

### Exportação

`Mapa mental (.png)` no menu de exportar e no botão da própria barra do mapa. Renderiza a
**extensão natural** do mapa, sem `frame` fixo: é a armadilha da largura fixa do
infográfico com o sinal trocado — lá o perigo era o cartão mudar de forma com a janela,
aqui é o mapa sair cortado justamente porque a pessoa deu zoom para trabalhar num ramo. O
mapa de 23 nós da reunião de 68 min saiu em 1970×1278 px, 235 KB.

### Verificação

`make smoke-mindmap` não se contenta com "não travou": mede a geometria calculada.

| Verificação | Resultado |
|---|---|
| 23 nós, 929×541 pt | nenhum par de nós se sobrepõe |
| Ligações | nenhuma aponta para trás (filho à esquerda do pai) |
| Área calculada | todo nó cabe dentro dela — a imagem não corta |
| Criar, renomear, mover, apagar | ok, inclusive a recusa de mover um nó para dentro de si |
| Fusão | preserva a edição; mapa idêntico não duplica nada |
| PNG | 1970×1278 px, ≥ 2× a largura do layout |

A interface interativa — pan, zoom, arrastar para outro pai e o campo de renomear — foi
conferida na tela pelo Ilan em 20/08/2026. O que os testes cobrem é a geometria e a
persistência; os gestos, só o olho.

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

## O abort ao encerrar — corrigido em 20/08/2026

O sintoma era "o app aborta ao encerrar", num assert do ggml/Metal
(`ggml_metal_device_free` durante `exit`, via `__cxa_finalize_ranges`). Os dez crash logs
diziam mais: **todos** vinham do `SmokeTest.report`, nenhum de um encerramento comum.

O assert é `GGML_ASSERT([rsets->data count] == 0)` em `ggml_metal_rsets_free`, com o
comentário "most likely you haven't deallocated all Metal resources before exiting". Cada
buffer Metal entra num residency set do dispositivo ao ser criado e sai ao ser liberado; o
vetor global de dispositivos é destruído na saída do processo e confere se o conjunto
ficou vazio.

Não é vazamento nosso: o `whisper_context` é liberado no `deinit` do `WhisperEngine`, e um
`--smoke-transcribe` que roda até o fim encerra limpo — confirmado. O que existe é uma
**janela**: parar de gravar dispara a transcrição, e o `--smoke-record` encerra 0,5 s
depois, com o contexto vivo. O mesmo acontece com quem fecha o app logo após uma reunião.

Interromper o whisper antes de sair não salvaria nada — a transcrição só vai a disco
quando termina. Então o encerramento passa por `Termination.exitNow`, que sai com `_exit`
e não roda os destrutores estáticos do C++. ⚠ `_exit` pula os `atexit`, inclusive o flush
do stdout, que é bufferizado quando a saída vai para um pipe (`make smoke-record | tail`):
há um `fflush(nil)` explícito, e um `UserDefaults.synchronize()` porque escritas recentes
de preferência são assíncronas.

Verificado: `--smoke-record 8` reproduzia o abort antes e não gera crash log depois, com a
saída do teste intacta; encerramento pelo menu e `--smoke-transcribe` continuam saindo com
código 0.

**Fechar o app durante a transcrição não perde mais a gravação.** A transcrição em si se
perde — nada vai a disco antes do fim —, mas `enqueue` grava `awaitingTranscription` no
`metadata.json` antes de começar, e a abertura seguinte retoma o que ficou marcado.

⚠ Vai pela marca, e **não** por "toda gravação sem transcript". São coisas diferentes:
esta biblioteca tem oito gravações sem transcrição que ninguém pediu para transcrever, e a
regra ingênua as moeria a cada abertura, minutos de CPU por vez, sem nunca dar em nada. A
marca cai quando a tentativa acaba — bem ou mal —, senão uma falha por áudio corrompido se
repetiria para sempre.

Verificado nos dois sentidos: matando o processo no meio de uma transcrição, a marca fica
de pé e a abertura seguinte a conclui sozinha; as oito sem marca continuam intactas depois
de 30 s de app aberto.

---

## Notarização — pronta, faltando duas credenciais

`make notarize` faz o caminho inteiro: assina com Developer ID (hardened runtime,
timestamp, entitlements), gera o DMG, envia para a Apple, espera, grampeia o carimbo e
confere como o Gatekeeper vai ver — inclusive abrindo o DMG e testando o app **de dentro
dele**, que é a cópia que chega na outra máquina.

O script recusa começar sem os dois pré-requisitos, com a instrução na tela:

1. **Certificado "Developer ID Application"** no keychain de login. Xcode → Settings →
   Accounts → sua Apple ID → Manage Certificates → "+" → Developer ID Application. Exige
   conta paga do Developer Program; a Apple ID solta do Xcode não serve.
2. **Credenciais do notarytool**, guardadas uma vez:
   `xcrun notarytool store-credentials capita --apple-id … --team-id … --password …`.
   A senha é uma *app-specific password* de appleid.apple.com, nunca a senha da conta.

⚠ **O hardened runtime, que a notarização exige, fecha o áudio por padrão.** Sem
`com.apple.security.device.audio-input` o app assinado abre, roda e grava **silêncio** —
o pedido de permissão nem chega a aparecer. `Resources/Capita.entitlements` existe por
isso, e o `notarize.sh` confere as duas coisas (flag `runtime` e o entitlement) antes de
enviar, porque descobrir depois custa a viagem inteira.

Testado antes de ter o certificado: o app assinado **com hardened runtime e o
entitlement**, usando o certificado local, gravou as duas trilhas com sinal de verdade
(RMS 2646 no sistema, 1767 no microfone) e não pediu permissão de novo. O que falta provar
na Apple é só a notarização em si.

⚠ Assinar com Developer ID muda o Designated Requirement, e o macOS trata isso como outro
app: as permissões de microfone e de gravação de áudio serão pedidas mais uma vez, na
primeira execução da versão distribuída. Uma vez só.

---

## Próximas fases

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
Capita --smoke-title [id]            # gera e salva o título de uma gravação transcrita
Capita --smoke-mindmap [id]          # geometria, edição, fusão e imagem do mapa mental
Capita --open-summary [id]           # abre a biblioteca já na ata daquela gravação
make notarize                        # assina com Developer ID, notariza e grampeia o DMG
Capita --smoke-transcribe [id] --title   # transcreve e nomeia: a corrente inteira
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
