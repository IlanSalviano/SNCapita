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

    static func log(_ message: String) {
        logger.debug("\(message, privacy: .public)")
        FileHandle.standardError.write(Data("[capita] \(message)\n".utf8))
    }
}
