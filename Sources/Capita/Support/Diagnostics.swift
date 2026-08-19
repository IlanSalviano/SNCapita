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
    static func log(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        FileHandle.standardError.write(Data("[capita] \(message)\n".utf8))
    }
}
