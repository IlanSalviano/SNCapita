import AppKit
import CoreGraphics

/// Percebe o duplo toque em Command, de qualquer app, durante a gravação.
///
/// É o gesto de pedir ajuda no meio da reunião: não tira as mãos do teclado, não tira o
/// foco da chamada e não colide com atalho nenhum — Command sozinho não faz nada no macOS.
///
/// Usa um event tap só de leitura, que exige a permissão de Monitoramento de Entrada. A
/// alternativa sem permissão seria consultar o estado das teclas dezenas de vezes por
/// segundo; o tap só acorda o app quando uma tecla muda. E só existe durante a gravação.
@MainActor
final class CommandDoubleTapDetector {

    var onDoubleTap: (() -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var recognizer = DoubleTapRecognizer()

    static var isAuthorized: Bool { CGPreflightListenEventAccess() }

    /// Mostra o pedido do sistema na primeira vez; depois, só os Ajustes mudam a resposta.
    @discardableResult
    static func requestAccess() -> Bool { CGRequestListenEventAccess() }

    /// Começa a escutar. Falso se o sistema recusou o tap — sem permissão ou, logo depois
    /// de concedê-la, porque o macOS só a aplica a um processo aberto depois dela.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }

        let types: [CGEventType] = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | CGEventMask(1) << $1.rawValue }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: Self.callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Diagnostics.log("duplo ⌘: tap recusado (Monitoramento de Entrada: "
                            + "\(Self.isAuthorized ? "concedido" : "negado"))")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        recognizer = DoubleTapRecognizer()
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    /// Roda na main thread: a fonte do tap está no run loop principal.
    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let detector = Unmanaged<CommandDoubleTapDetector>.fromOpaque(userInfo)
            .takeUnretainedValue()
        let flags = event.flags
        MainActor.assumeIsolated {
            detector.handle(type, flags: flags)
        }
        return Unmanaged.passUnretained(event)
    }

    private func handle(_ type: CGEventType, flags: CGEventFlags) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // O sistema desliga um tap que demora a responder; religamos em vez de ficar
            // surdo pelo resto da reunião.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .flagsChanged:
            if recognizer.modifiersChanged(flags, at: ProcessInfo.processInfo.systemUptime) {
                onDoubleTap?()
            }
        default:
            recognizer.otherInput()
        }
    }
}

/// Distingue um duplo toque em Command de um atalho que usa Command.
///
/// Um toque vale só se Command desceu e subiu sozinho e depressa: nenhuma tecla, clique
/// ou outro modificador no meio. Assim ⌘C, ⌘⇥ ou ⌘-clique repetidos nunca disparam.
struct DoubleTapRecognizer {

    /// Mais que isto segurando Command já não é um toque.
    static let maximumHold: TimeInterval = 0.35
    /// Tempo máximo entre o fim do primeiro toque e o fim do segundo.
    static let maximumGap: TimeInterval = 0.45

    private var commandDownAt: TimeInterval?
    private var tainted = false
    private var lastTapAt: TimeInterval?

    /// Devolve true quando o segundo toque completa o gesto.
    mutating func modifiersChanged(_ flags: CGEventFlags, at time: TimeInterval) -> Bool {
        let command = flags.contains(.maskCommand)
        let others = !flags.intersection([.maskShift, .maskControl, .maskAlternate]).isEmpty

        if command {
            if commandDownAt == nil {
                commandDownAt = time
                tainted = others
            } else if others {
                tainted = true
            }
            return false
        }

        guard let downAt = commandDownAt else {
            // Outro modificador soltou, sem Command: não afeta um gesto em curso.
            return false
        }
        commandDownAt = nil

        guard !tainted, time - downAt <= Self.maximumHold else {
            lastTapAt = nil
            return false
        }
        if let last = lastTapAt, time - last <= Self.maximumGap {
            lastTapAt = nil
            return true
        }
        lastTapAt = time
        return false
    }

    /// Qualquer tecla ou clique: um Command pressionado agora é parte de um atalho.
    mutating func otherInput() {
        if commandDownAt != nil { tainted = true }
        lastTapAt = nil
    }
}
