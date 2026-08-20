import SwiftUI

/// O mapa mental como mapa: espacial, editável, exportável.
///
/// A árvore de leitura que existia antes estava correta e era inútil para o que as pessoas
/// fazem com um mapa mental — que é mexer nele. A IA acerta a estrutura em linhas gerais e
/// erra nos detalhes que só quem estava na reunião conhece; sem poder corrigir um ramo,
/// acrescentar o que faltou e reorganizar, o mapa vira mais um bloco de texto.
///
/// Toda edição vai para `mindmap.json` na hora. Não há "salvar": o arquivo é minúsculo, e
/// um botão de salvar só criaria a chance de perder trabalho ao fechar a janela.
struct MindMapEditor: View {
    let recording: Recording
    let summary: MeetingSummary

    @Environment(AppState.self) private var state

    @State private var map: MindMap?
    @State private var selection: UUID?
    @State private var editing: UUID?
    @State private var draft = ""
    @FocusState private var isEditingFocused: Bool

    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var gestureZoom: CGFloat = 1
    @State private var gesturePan: CGSize = .zero

    @State private var dragging: UUID?
    @State private var dragOffset: CGSize = .zero
    @State private var dropTarget: UUID?
    @State private var pendingDeletion: MindMapLayout.Placed?

    private static let space = "mind-map-content"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let map {
                let layout = MindMapLayout.compute(map)

                toolbar(layout)
                if case .editedAndOutdated = state.mindMaps.divergence(map, against: summary) {
                    divergenceBanner
                }
                canvas(layout)

                // O mapa não anuncia sozinho que é editável: os gestos que importam —
                // renomear e mudar de pai — não têm botão que os revele.
                Text(S.mindMapHint)
                    .font(Design.Typography.caption)
                    .foregroundStyle(Design.Palette.secondaryLabel)
            }
        }
        .task(id: recording.id) { load() }
        .onChange(of: state.summaries.currentRecordingID) { _, current in
            // O resumo acabou de ser refeito: recarrega para o aviso de divergência
            // aparecer sem precisar trocar de gravação e voltar.
            if current == nil { load() }
        }
        .confirmationDialog(
            S.deleteBranchQuestion(pendingDeletion?.label ?? ""),
            isPresented: Binding(get: { pendingDeletion != nil },
                                 set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button(S.deleteBranch, role: .destructive) {
                if let id = pendingDeletion?.id { apply { $0.remove(id) } }
                pendingDeletion = nil
                selection = nil
            }
        }
    }

    // MARK: - Barra

    private func toolbar(_ layout: MindMapLayout.Result) -> some View {
        HStack(spacing: 6) {
            Text(S.mindMap).font(Design.Typography.sectionHeading)

            Spacer(minLength: 12)

            Button { addChild() } label: { Image(systemName: "plus") }
                .help(S.mindMapAddChild)
                .disabled(selection == nil)
            Button { addSibling() } label: { Image(systemName: "arrow.turn.down.right") }
                .help(S.mindMapAddSibling)
                .disabled(selection == nil || selection == map?.root.id)
            Button { requestDelete(layout) } label: { Image(systemName: "minus") }
                .help(S.mindMapDelete)
                .disabled(selection == nil || selection == map?.root.id)

            Divider().frame(height: 14)

            Button { setZoom(zoom - 0.15) } label: { Image(systemName: "minus.magnifyingglass") }
                .help(S.mindMapZoomOut)
            Button { fit(layout) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .help(S.mindMapFit)
            Button { setZoom(zoom + 0.15) } label: { Image(systemName: "plus.magnifyingglass") }
                .help(S.mindMapZoomIn)

            Divider().frame(height: 14)

            Button {
                if let map { state.export.exportMindMap(recording, map: map, title: summary.title) }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .help(S.exportMindMap)
        }
        .buttonStyle(IconButtonStyle())
        .font(Design.Typography.caption)
    }

    private var divergenceBanner: some View {
        Banner(icon: "arrow.triangle.branch", text: S.mindMapOutdated,
               action: S.mindMapGraft) {
            guard let generated = summary.mindMap else { return }
            apply { $0.graftNewBranches(from: generated) }
        }
        .overlay(alignment: .trailing) {
            // As outras duas saídas ficam num menu: a principal — trazer o que falta — é
            // a única que não perde nada, e as que perdem não devem estar a um clique.
            Menu {
                Button(S.mindMapUseNew) {
                    guard let generated = summary.mindMap else { return }
                    apply { $0.replace(with: generated) }
                }
                Button(S.mindMapKeepMine) {
                    guard let generated = summary.mindMap else { return }
                    apply { $0.keepMine(against: generated) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .buttonStyle(IconButtonStyle())
            .menuStyle(.borderlessButton)
            .frame(width: 26)
            .padding(.trailing, 6)
        }
    }

    // MARK: - Tela

    private func canvas(_ layout: MindMapLayout.Result) -> some View {
        GeometryReader { geometry in
            ZStack {
                // Fundo: recebe o arrasto de pan e o clique que desfaz a seleção. Precisa
                // de cor (mesmo transparente) para existir para o hit test.
                Rectangle()
                    .fill(Design.Palette.card.opacity(0.5))
                    .contentShape(Rectangle())
                    .onTapGesture { selection = nil; editing = nil }
                    .gesture(
                        DragGesture()
                            .onChanged { gesturePan = $0.translation }
                            .onEnded { value in
                                pan.width += value.translation.width
                                pan.height += value.translation.height
                                gesturePan = .zero
                            })

                content(layout)
                    .frame(width: layout.size.width, height: layout.size.height)
                    .coordinateSpace(.named(Self.space))
                    .scaleEffect(zoom * gestureZoom, anchor: .center)
                    .offset(x: pan.width + gesturePan.width,
                            y: pan.height + gesturePan.height)
            }
            .clipped()
            .gesture(
                MagnifyGesture()
                    .onChanged { gestureZoom = $0.magnification }
                    .onEnded { value in
                        setZoom(zoom * value.magnification)
                        gestureZoom = 1
                    })
            .onAppear { if pan == .zero { fit(layout, in: geometry.size) } }
        }
        .frame(height: 460)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Design.Palette.card.opacity(0.35)))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Design.Palette.cardBorder))
        // O foco é do quadro inteiro: as teclas agem sobre a seleção, e exigir clicar num
        // nó "para dar foco" antes de usar Tab seria uma etapa inventada.
        .focusable()
        .onKeyPress { press in handle(press, layout: layout) }
    }

    private func content(_ layout: MindMapLayout.Result) -> some View {
        ZStack(alignment: .topLeading) {
            MindMapEdges(layout: layout)

            ForEach(layout.nodes) { placed in
                MindMapNodeView(
                    placed: placed,
                    isSelected: selection == placed.id,
                    isDropTarget: dropTarget == placed.id,
                    isEditing: editing == placed.id,
                    draft: $draft,
                    focus: $isEditingFocused,
                    commit: { commitEdit(placed.id) },
                    cancel: { editing = nil })
                .position(x: placed.frame.midX, y: placed.frame.midY)
                .offset(dragging == placed.id ? dragOffset : .zero)
                .zIndex(dragging == placed.id ? 1 : 0)
                .onTapGesture(count: 2) { startEdit(placed) }
                .onTapGesture { selection = placed.id; editing = nil }
                .gesture(dragGesture(for: placed, in: layout))
            }
        }
    }

    /// Arrastar um nó para cima de outro o adota. É o gesto que reorganiza o mapa.
    private func dragGesture(
        for placed: MindMapLayout.Placed, in layout: MindMapLayout.Result
    ) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named(Self.space))
            .onChanged { value in
                guard placed.id != map?.root.id else { return }
                dragging = placed.id
                dragOffset = value.translation
                dropTarget = target(at: value.location, dragging: placed.id, in: layout)
            }
            .onEnded { value in
                defer { dragging = nil; dragOffset = .zero; dropTarget = nil }
                guard placed.id != map?.root.id,
                      let parent = target(at: value.location, dragging: placed.id, in: layout)
                else { return }
                apply { $0.move(placed.id, under: parent) }
                selection = placed.id
            }
    }

    /// Sobre qual nó o ponto caiu, ignorando o que está sendo arrastado e a subárvore dele
    /// — soltar um nó dentro de si mesmo desconectaria o ramo inteiro do mapa.
    private func target(
        at point: CGPoint, dragging id: UUID, in layout: MindMapLayout.Result
    ) -> UUID? {
        guard let map else { return nil }
        return layout.nodes.first { placed in
            placed.frame.insetBy(dx: -6, dy: -6).contains(point)
                && placed.id != id
                && !map.contains(placed.id, inSubtreeOf: id)
                && map.parent(of: id) != placed.id
        }?.id
    }

    // MARK: - Teclado

    private func handle(_ press: KeyPress, layout: MindMapLayout.Result) -> KeyPress.Result {
        guard editing == nil else { return .ignored }

        switch press.key {
        case .tab:      addChild();   return .handled
        case .return:   addSibling(); return .handled
        case .delete, .deleteForward:
            requestDelete(layout)
            return .handled
        case .escape:
            selection = nil
            return .handled
        case .space:
            if let selection, let placed = layout.node(selection) { startEdit(placed) }
            return .handled
        default:
            return .ignored
        }
    }

    // MARK: - Edição

    private func load() {
        map = state.mindMaps.mapOrCreate(for: recording.id, from: summary)
        selection = nil
        editing = nil
    }

    /// Toda mutação passa por aqui: muda, salva, e devolve o mapa ao estado da view. Ter
    /// um único caminho é o que garante que nenhuma edição fique só na tela.
    private func apply(_ change: (inout MindMap) -> Void) {
        guard var current = map else { return }
        change(&current)
        try? state.mindMaps.store(current, for: recording.id)
        map = current
    }

    private func addChild() {
        guard let parent = selection ?? map?.root.id else { return }
        var created: UUID?
        apply { created = $0.addChild(S.mindMapNewNode, to: parent) }
        if let created {
            selection = created
            startEdit(id: created, label: S.mindMapNewNode)
        }
    }

    private func addSibling() {
        guard let selection, selection != map?.root.id else { return }
        var created: UUID?
        apply { created = $0.addSibling(S.mindMapNewNode, after: selection) }
        if let created {
            self.selection = created
            startEdit(id: created, label: S.mindMapNewNode)
        }
    }

    private func requestDelete(_ layout: MindMapLayout.Result) {
        guard let selection, selection != map?.root.id,
              let placed = layout.node(selection), let node = map?.node(selection)
        else { return }

        // Folha some sem cerimônia; ramo com filhos pergunta. Apagar cinco nós por engano
        // com uma tecla, sem desfazer, seria o único jeito de perder trabalho aqui.
        if node.children.isEmpty {
            apply { $0.remove(selection) }
            self.selection = nil
        } else {
            pendingDeletion = placed
        }
    }

    private func startEdit(_ placed: MindMapLayout.Placed) {
        startEdit(id: placed.id, label: placed.label)
    }

    private func startEdit(id: UUID, label: String) {
        selection = id
        draft = label
        editing = id
        DispatchQueue.main.async { isEditingFocused = true }
    }

    private func commitEdit(_ id: UUID) {
        apply { $0.rename(id, to: draft) }
        editing = nil
    }

    // MARK: - Zoom e enquadramento

    private func setZoom(_ value: CGFloat) {
        zoom = min(2.5, max(0.3, value))
    }

    private func fit(_ layout: MindMapLayout.Result, in available: CGSize? = nil) {
        let size = available ?? CGSize(width: 720, height: 460)
        guard layout.size.width > 0, layout.size.height > 0 else { return }
        setZoom(min(size.width / layout.size.width, size.height / layout.size.height))
        pan = .zero
        gesturePan = .zero
    }
}

// MARK: - Peças

/// As ligações, num `Canvas`: são centenas de traços que não precisam de identidade nem de
/// hit test próprios, e desenhá-las como views custaria caro à toa.
private struct MindMapEdges: View {
    let layout: MindMapLayout.Result

    var body: some View {
        Canvas { context, _ in
            for edge in layout.edges {
                var path = Path()
                path.move(to: edge.from)
                // Curva em S: o cotovelo reto de um organograma sugere hierarquia rígida,
                // que é o oposto do que um mapa mental representa.
                let midX = (edge.from.x + edge.to.x) / 2
                path.addCurve(
                    to: edge.to,
                    control1: CGPoint(x: midX, y: edge.from.y),
                    control2: CGPoint(x: midX, y: edge.to.y))
                context.stroke(path, with: .color(Design.Palette.cardBorder), lineWidth: 1.5)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct MindMapNodeView: View {
    let placed: MindMapLayout.Placed
    let isSelected: Bool
    let isDropTarget: Bool
    let isEditing: Bool
    @Binding var draft: String
    var focus: FocusState<Bool>.Binding
    let commit: () -> Void
    let cancel: () -> Void

    var body: some View {
        Group {
            if isEditing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .focused(focus)
                    .onSubmit(commit)
                    .onExitCommand(perform: cancel)
                    .onChange(of: focus.wrappedValue) { _, focused in
                        // Clicar fora salva: num campo que nasce no meio do mapa, exigir
                        // Enter faria perder o texto ao clicar no próximo nó.
                        if !focused { commit() }
                    }
            } else {
                Text(placed.label)
                    .font(Font(MindMapLayout.font(depth: placed.depth)))
                    .foregroundStyle(placed.depth > 1
                                     ? Design.Palette.secondaryLabel : Design.Palette.label)
                    .multilineTextAlignment(.leading)
            }
        }
        .frame(width: placed.frame.width - 22, height: placed.frame.height - 14,
               alignment: .leading)
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(placed.depth == 0
                      ? Design.Palette.accent.opacity(0.08) : Design.Palette.surface))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(border, lineWidth: isSelected || isDropTarget ? 2 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var border: Color {
        if isDropTarget { return Design.Palette.accent }
        if isSelected { return Design.Palette.accent.opacity(0.6) }
        return Design.Palette.cardBorder
    }
}

/// O mapa inteiro, sem interação — o que vai para o PNG.
struct MindMapStatic: View {
    let map: MindMap
    let title: String

    /// Nunca recebe foco: existe porque o nó é a mesma view do editor, e ela precisa de um
    /// `FocusState` para o campo de renomear. Fora do editor não há campo nenhum.
    @FocusState private var neverFocused: Bool

    var body: some View {
        let layout = MindMapLayout.compute(map)

        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(Design.Typography.displayTitle)

            ZStack(alignment: .topLeading) {
                MindMapEdges(layout: layout)
                ForEach(layout.nodes) { placed in
                    MindMapNodeView(
                        placed: placed, isSelected: false, isDropTarget: false,
                        isEditing: false, draft: .constant(""),
                        focus: $neverFocused, commit: {}, cancel: {})
                    .position(x: placed.frame.midX, y: placed.frame.midY)
                }
            }
            .frame(width: layout.size.width, height: layout.size.height)
        }
        .padding(28)
        .background(Design.Palette.surface)
    }
}
