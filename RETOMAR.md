# Onde paramos — 18/08/2026

Fases 0, 1 e 2 entregues e funcionando. O app está instalado em `~/Applications/Capita.app`
e aparece na barra de menus (não no Dock).

```bash
make run     # compila, instala e abre
make stop    # encerra
```

---

## O teste que falta: gravar com fone de ouvido

É o único teste que prova a tese central do produto — que a separação **você × outros**
funciona. Até agora só testei com alto-falantes, e por isso as duas trilhas capturaram o
mesmo áudio: o microfone ouvia o que saía das caixas.

**Como testar**

1. Coloque o fone. Entre numa reunião real (Teams ou Zoom, app nativo).
2. Clique no ícone de onda na barra de menus → **Iniciar gravação**.
3. Fale, e deixe a outra pessoa falar.
4. Pare pela cápsula flutuante. A gravação aparece em "Gravações recentes" com um
   indicador de progresso enquanto transcreve.
5. Abra a biblioteca pelo ícone de pasta e confira o transcript.

**O que observar**

| Verificação | Por que importa |
|---|---|
| Alguma permissão pediu senha de **administrador**? | Se pedir, a arquitetura inteira precisa ser repensada — ela existe para evitar isso. |
| Sua voz saiu como "Você" e a do outro como "Outros"? | É a tese do produto. Com fone, as trilhas devem se separar de verdade. |
| Faltou alguma frase? | Os filtros anti-alucinação podem estar cortando fala legítima. |
| **Apareceu alguma frase que ninguém disse?** | O ponto mais importante — ver abaixo. |
| A janela de biblioteca abriu na frente? | Nunca consegui confirmar visualmente (Outlook em tela cheia noutro Space). |

**Se aparecer frase inventada**, capture os números do descarte:

```bash
log stream --predicate 'subsystem == "com.ilansalviano.capita"'
```

Repetir também no **navegador** (Chrome): é o caso que justifica capturar o sistema
inteiro em vez de filtrar pelo app da reunião.

---

## Ressalva honesta sobre o estado atual

A defesa contra frases inventadas **não foi exercitada** desde que afrouxei os filtros para
parar de cortar fala legítima. Nenhuma alucinação apareceu nos testes seguintes — o que
não é prova de que a proteção funciona, apenas de que não foi provocada. Uma reunião real,
com silêncios longos e ruído de sala, é o que vai testá-la.

Detalhes da calibração e os números medidos estão na seção *Qualidade da transcrição* do
`README.md`.

---

## Decisões em aberto

**1. Motor de IA para os sumários (bloqueia a Fase 4).**
O Claude Code CLI não pode ser embarcado no `.dmg` — depende da sua conta e autenticação.
Numa máquina sem ele, sumários e Ask AI não funcionam. As opções:

| Opção | Custo | Consequência |
|---|---|---|
| LLM local via llama.cpp | +2–4 GB no DMG | Atende "tudo embarcado"; qualidade abaixo do Claude |
| Detectar `claude` e usar se existir | zero | Qualidade máxima na sua máquina, nada na dos outros |
| Campo para chave de API | zero | Portátil, mas cada usuário precisa de chave paga |

**2. Notarização.** Você vai providenciar a conta Apple Developer. Sem ela o DMG não abre
em outra máquina: o macOS 26 só oferece "Mover para o Lixo".

---

## Próximo passo combinado

**Fase 3 — diarização**: distinguir os participantes entre si dentro da trilha do sistema.
Direção já pesquisada: **FluidAudio** (SPM, Apache-2.0, pyannote Community-1 em CoreML
rodando na ANE, suporta modelos embarcados) ou **sherpa-onnx** com pyannote-seg-3.0 (MIT)
+ WeSpeaker CAM++ (Apache-2.0), ~35 MB no total.

⚠ Evitar os modelos `reverb-diarization`: a licença proíbe uso comercial.

O plano completo, com as fases 4 a 7, está em
`~/.claude/plans/indexed-puzzling-kahan.md`.
