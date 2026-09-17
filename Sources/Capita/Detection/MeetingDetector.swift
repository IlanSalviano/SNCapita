import Foundation
import Observation

/// Um app capaz de hospedar uma reunião.
///
/// `bundleID` é um **prefixo**, não o identificador exato. O áudio de um navegador não sai
/// do processo principal e sim de um auxiliar (`com.google.Chrome.helper`), e o Teams
/// mudou de `com.microsoft.teams` para `...teams2` sem trocar de nome. Casar por prefixo
/// cobre os dois casos e mantém as variantes de um mesmo app como uma reunião só.
struct MeetingApp: Equatable, Sendable, Identifiable {
    let bundleID: String
    let name: String

    var id: String { bundleID }

    /// Os navegadores estão aqui por causa do Meet, que não tem app próprio. Não dá para
    /// saber qual aba abriu o microfone sem a permissão de Acessibilidade — e pedi-la só
    /// para escrever "Meet" em vez de "Chrome" no aviso seria um mau negócio. O aviso diz
    /// o que se sabe de verdade: qual app abriu o microfone.
    private static let known: [MeetingApp] = [
        MeetingApp(bundleID: "us.zoom.xos", name: "Zoom"),
        MeetingApp(bundleID: "com.microsoft.teams", name: "Teams"),
        MeetingApp(bundleID: "Cisco-Systems.Spark", name: "Webex"),
        MeetingApp(bundleID: "com.webex.meetingmanager", name: "Webex"),
        MeetingApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack"),
        MeetingApp(bundleID: "com.google.Chrome", name: "Chrome"),
        MeetingApp(bundleID: "com.apple.Safari", name: "Safari"),
        MeetingApp(bundleID: "com.microsoft.edgemac", name: "Edge"),
        MeetingApp(bundleID: "com.brave.Browser", name: "Brave"),
        MeetingApp(bundleID: "org.mozilla.firefox", name: "Firefox"),
        MeetingApp(bundleID: "company.thebrowser.Browser", name: "Arc"),
    ]

    static func match(_ bundleID: String) -> MeetingApp? {
        known.first { bundleID.hasPrefix($0.bundleID) }
    }
}

/// Percebe que uma reunião começou e que ela acabou.
///
/// O sinal é o microfone: enquanto um app de reunião mantém a entrada de áudio aberta,
/// há uma chamada em curso. A alternativa — olhar quais apps estão abertos — não serve,
/// porque o Teams fica aberto o dia inteiro e o navegador também.
///
/// Os dois limiares são assimétricos de propósito, porque os erros custam coisas
/// diferentes: perguntar "quer gravar?" no meio de um teste de áudio é um incômodo
/// gratuito, enquanto avisar tarde demais que a reunião acabou não custa quase nada.
@MainActor
@Observable
final class MeetingDetector {

    struct Meeting: Equatable, Sendable {
        let app: MeetingApp
        let startedAt: Date
    }

    private(set) var activeMeeting: Meeting?

    var onStarted: ((Meeting) -> Void)?
    var onEnded: ((Meeting) -> Void)?

    /// Ligado por padrão: quem instala um gravador de reuniões quer ser avisado delas.
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.preferenceKey)
            isEnabled ? start() : stop()
        }
    }

    private static let preferenceKey = "meetings.detectionEnabled"

    private static let pollInterval: TimeInterval = 2

    /// Quanto tempo o microfone precisa ficar aberto para virar "reunião". O Zoom abre a
    /// entrada na tela de teste de áudio, antes de a pessoa entrar de fato; avisar ali
    /// seria avisar de uma reunião que ainda não existe.
    static let startConfirmation: TimeInterval = 10

    /// Quanto tempo o app da reunião precisa ficar sem áudio nenhum — nem entrada, nem
    /// saída — para a reunião ser dada por encerrada.
    ///
    /// Começou em 45s, por medo de encerrar uma reunião que só tinha ficado quieta. Uma
    /// reunião real de 55 minutos mostrou que o medo era infundado: o app manteve entrada
    /// e saída abertas do começo ao fim, sem um único intervalo de silêncio — porque o
    /// que o CoreAudio reporta é o *stream* aberto, não o som saindo dele. Uma chamada em
    /// curso nunca fica quieta nesse sentido, nem com todo mundo mudo.
    ///
    /// Os 45s, porém, custaram caro do outro lado: quem sai de uma chamada olha a tela
    /// por alguns segundos e vai fazer outra coisa. O lembrete chegava depois de a pessoa
    /// já ter parado a gravação na mão — ou seja, nunca chegava. 15s ainda absorvem uma
    /// troca de fone e chegam enquanto alguém ainda está olhando.
    static let endGrace: TimeInterval = 15

    private var timer: Timer?
    private var candidateSince: [String: Date] = [:]
    private var quietSince: Date?

    init() {
        isEnabled = UserDefaults.standard.object(forKey: Self.preferenceKey) as? Bool ?? true
    }

    func start() {
        guard isEnabled, timer == nil else { return }
        timer = Timer.scheduledTimer(
            withTimeInterval: Self.pollInterval, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        activeMeeting = nil
        candidateSince.removeAll()
        quietSince = nil
    }

    // MARK: - Ciclo de observação

    private func poll() {
        let now = Date()
        let processes = AudioProcesses.sample().filter {
            // O Capita abre o microfone para gravar. Sem esta linha ele detectaria a si
            // mesmo como reunião, e cada gravação dispararia um aviso de reunião nova.
            !$0.bundleID.hasPrefix(Self.ownBundlePrefix)
        }

        if let meeting = activeMeeting {
            watchForEnd(of: meeting, in: processes, now: now)
        } else {
            watchForStart(in: processes, now: now)
        }
    }

    private func watchForStart(in processes: [AudioProcesses.Process], now: Date) {
        var withOpenMic: Set<String> = []

        for process in processes where process.isRunningInput {
            guard let app = MeetingApp.match(process.bundleID) else { continue }
            withOpenMic.insert(app.bundleID)

            let since = candidateSince[app.bundleID] ?? now
            candidateSince[app.bundleID] = since

            guard now.timeIntervalSince(since) >= Self.startConfirmation else { continue }

            let meeting = Meeting(app: app, startedAt: since)
            activeMeeting = meeting
            candidateSince.removeAll()
            quietSince = nil
            Diagnostics.log("reunião detectada: \(app.name)")
            onStarted?(meeting)
            return
        }

        // Quem fechou o microfone antes de confirmar volta à estaca zero: dois blips de
        // cinco segundos não somam uma reunião de dez.
        candidateSince = candidateSince.filter { withOpenMic.contains($0.key) }
    }

    private func watchForEnd(
        of meeting: Meeting, in processes: [AudioProcesses.Process], now: Date
    ) {
        let stillLive = processes.contains {
            $0.bundleID.hasPrefix(meeting.app.bundleID) && $0.usesAudio
        }

        if stillLive {
            quietSince = nil
            return
        }

        guard let since = quietSince else {
            quietSince = now
            return
        }

        guard now.timeIntervalSince(since) >= Self.endGrace else { return }

        activeMeeting = nil
        quietSince = nil
        Diagnostics.log("reunião encerrada: \(meeting.app.name)")
        onEnded?(meeting)
    }

    private static let ownBundlePrefix = "com.ilansalviano.capita"
}
