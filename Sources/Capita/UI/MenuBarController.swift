import AppKit
import SwiftUI

/// Dono do item na barra de menus e do popover.
///
/// Usamos `NSStatusItem` em vez do `MenuBarExtra` do SwiftUI: o MenuBarExtra não criou o
/// item de forma confiável neste app, e o AppKit dá o controle explícito de que vamos
/// precisar de qualquer forma na Fase 1 — o painel flutuante não-ativante durante a
/// gravação não tem equivalente em SwiftUI puro.
@MainActor
final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let state: AppState

    /// Fecha o popover quando o usuário clica fora dele. Sem isso, o popover só fecharia
    /// clicando de novo no ícone, o que destoa do comportamento nativo do macOS.
    private var outsideClickMonitor: Any?

    init(state: AppState) {
        self.state = state
        super.init()
        setUpStatusItem()
        setUpPopover()
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let button = item.button else {
            assertionFailure("NSStatusItem sem botão — a barra de menus não aceitou o item")
            return
        }

        button.image = Self.icon(isRecording: false)
        button.target = self
        button.action = #selector(togglePopover)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        statusItem = item

        // O frame do item só é significativo depois que a barra de menus o posiciona —
        // logo após a criação ele ainda é (0,0,38,0). Registramos onde o item foi parar
        // porque, com múltiplos monitores, "o app não apareceu" quase sempre significa
        // "apareceu na outra tela".
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            let frame = button.window?.frame
            let displayed = (frame?.height ?? 0) > 0
            Diagnostics.log(
                "item na barra: \(displayed ? "exibido" : "NÃO exibido") "
                + "em \(button.window?.screen?.localizedName ?? "nenhuma tela") "
                + "\(frame?.debugDescription ?? "")")
        }
    }

    private func setUpPopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: Design.Metrics.popoverWidth, height: 200)
        popover.contentViewController = NSHostingController(
            rootView: PopoverView().environment(state))
    }

    // MARK: - Interação

    @objc private func togglePopover() {
        // Clique direito abre o menu de contexto; esquerdo, o popover.
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
            return
        }
        popover.isShown ? closePopover() : showPopover()
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeKey()

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.closePopover() }
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(
            withTitle: S.quit,
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        // Desanexa o menu logo em seguida, senão o clique esquerdo passaria a abri-lo
        // em vez do popover.
        statusItem?.menu = nil
    }

    /// Reflete o estado de gravação no ícone, para o usuário saber que está gravando
    /// mesmo com o popover fechado.
    func updateIcon(isRecording: Bool) {
        statusItem?.button?.image = Self.icon(isRecording: isRecording)
    }

    /// Monta o ícone da barra de menus.
    ///
    /// `isTemplate` precisa ser marcado **antes** da imagem ser atribuída ao botão. Sem
    /// isso o glifo é desenhado com a cor do tema do app (preto, em modo claro) em vez de
    /// se adaptar à barra — o que fica invisível quando o macOS escurece a barra de menus
    /// por causa de um wallpaper escuro, mesmo com o sistema em modo claro.
    private static func icon(isRecording: Bool) -> NSImage? {
        let name = isRecording ? "waveform.circle.fill" : "waveform"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: S.menuBarIcon)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 15, weight: .regular))
        image?.isTemplate = true
        return image
    }
}
