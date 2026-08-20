.PHONY: help build app dmg install run stop spike-tap smoke-record smoke-export \
        smoke-summarize smoke-title icon signing-cert clean check

APP      := build/Capita.app
INSTALLED := $(HOME)/Applications/Capita.app

help:
	@echo "Capita — gravador de reuniões para macOS"
	@echo
	@echo "  make spike-tap     Prova que a captura de áudio funciona sem admin"
	@echo "  make smoke-record  Grava 8s de verdade e confere as duas trilhas"
	@echo "  make smoke-export  Mixa e exporta a gravação mais recente para /tmp"
	@echo "  make smoke-summarize  Mostra a ata da gravação mais recente"
	@echo "  make smoke-title   Dá nome à gravação mais recente já transcrita"
	@echo "  make app           Compila e monta Capita.app"
	@echo "  make install       Instala em ~/Applications (sem admin)"
	@echo "  make run           Instala e abre"
	@echo "  make stop          Encerra o app"
	@echo "  make dmg           Gera o .dmg distribuível"
	@echo "  make signing-cert  Cria certificado estável (evita re-pedir permissões)"
	@echo "  make icon          Regenera o ícone .icns"
	@echo "  make check         Verifica o bundle (assinatura, plist, recursos)"
	@echo "  make clean         Remove artefatos de build"

build:
	swift build -c release

# O primeiro teste do projeto: se isto pedir senha de administrador, a arquitetura
# inteira precisa ser repensada. Toque algum áudio antes de rodar.
spike-tap: build
	@./.build/release/TapSpike

# Grava de verdade por 8s e confere as duas trilhas. Toque algum áudio enquanto roda.
smoke-record: install
	@pkill -f "Capita.app/Contents/MacOS/Capita" 2>/dev/null || true
	@"$(INSTALLED)/Contents/MacOS/Capita" --smoke-record 8

# Mixa as duas trilhas, escreve todos os formatos em /tmp e confere o resultado —
# inclusive se as duas trilhas sobreviveram à mixagem.
smoke-export: install
	@pkill -f "Capita.app/Contents/MacOS/Capita" 2>/dev/null || true
	@"$(INSTALLED)/Contents/MacOS/Capita" --smoke-export

# Gera o título de uma gravação já transcrita (ARGS=<prefixo-do-id>) e o salva.
smoke-title: install
	@pkill -f "Capita.app/Contents/MacOS/Capita" 2>/dev/null || true
	@"$(INSTALLED)/Contents/MacOS/Capita" --smoke-title $(ARGS)

# Sem --force apenas mostra a ata salva: resumir custa minutos e, no Claude Code, dinheiro.
smoke-summarize: install
	@pkill -f "Capita.app/Contents/MacOS/Capita" 2>/dev/null || true
	@"$(INSTALLED)/Contents/MacOS/Capita" --smoke-summarize $(ARGS)

icon:
	@swift scripts/make-icon.swift Resources/AppIcon.icns

app:
	@./scripts/make-app.sh

dmg: app
	@./scripts/make-dmg.sh

signing-cert:
	@./scripts/make-signing-cert.sh

install: app
	@rm -rf "$(INSTALLED)"
	@mkdir -p "$(HOME)/Applications"
	@cp -R "$(APP)" "$(INSTALLED)"
	@echo "▸ Instalado em $(INSTALLED)"

run: install
	@pkill -f "Capita.app/Contents/MacOS/Capita" 2>/dev/null || true
	@open "$(INSTALLED)"
	@echo "▸ Capita rodando — procure o ícone de onda na barra de menus"

stop:
	@pkill -f "Capita.app/Contents/MacOS/Capita" 2>/dev/null \
		&& echo "▸ Encerrado" || echo "▸ Não estava rodando"

check: app
	@echo "▸ Assinatura"
	@codesign --verify --strict --verbose=2 $(APP) 2>&1 | sed 's/^/    /'
	@echo "▸ Designated Requirement (cdhash puro = permissões serão re-pedidas)"
	@codesign -d --requirements - $(APP) 2>&1 | grep designated | sed 's/^/    /'
	@echo "▸ Info.plist"
	@plutil -lint $(APP)/Contents/Info.plist | sed 's/^/    /'
	@echo "▸ Recursos"
	@ls -1 $(APP)/Contents/Resources | sed 's/^/    /'

clean:
	@rm -rf .build build
	@echo "▸ Limpo"
