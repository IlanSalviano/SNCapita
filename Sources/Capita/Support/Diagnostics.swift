import Foundation
import os

/// Log de diagnóstico do app.
///
/// Escreve no unified log do macOS (visível com `log stream --predicate 'subsystem ==
/// "com.ilansalviano.capita"'`) e também em stderr, porque um agente de barra de menus
/// lançado com `open` não tem terminal onde imprimir — e durante o desenvolvimento é
/// pelo stderr que enxergamos o que aconteceu.
enum Diagnostics {
    private static let logger = Logger(
        subsystem: "com.ilansalviano.capita", category: "app")

    /// Usamos `notice`, não `debug`: o macOS descarta mensagens de debug da memória e elas
    /// não aparecem no `log show` depois do fato. Como o valor deste log está justamente
    /// em investigar o que aconteceu numa gravação já encerrada, precisam ser persistidas.
    /// `--open-summary <prefixo-do-id>` abre a biblioteca já na ata daquela gravação.
    ///
    /// Existe para encurtar o laço quando se está mexendo no resumo ou no mapa mental:
    /// sem isso, cada build a conferir custa abrir a janela, achar a gravação na lista e
    /// trocar de aba. É também o único jeito de fotografar a tela certa sem clicar nela.
    static var opensSummary: Bool {
        CommandLine.arguments.contains("--open-summary")
    }

    static func requestedRecording(among recordings: [Recording]) -> Recording? {
        guard let prefix = CommandLine.arguments
            .drop(while: { $0 != "--open-summary" }).dropFirst().first
        else { return nil }
        return recordings.first {
            $0.id.uuidString.lowercased().hasPrefix(prefix.lowercased())
        }
    }

    static func log(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        FileHandle.standardError.write(Data("[capita] \(message)\n".utf8))
    }
}
