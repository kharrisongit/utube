import SwiftUI
import Observation

struct ConversationTurn: Identifiable {
    var id = UUID()
    var question: String
    var response: GroundedAnswer?
    var sources: [Evidence] = []
    var error: String?
}

@MainActor @Observable
final class ChatController {
    var draft = ""
    var turns: [ConversationTurn] = []
    var busy = false
    var requestedNavigation = false
    var thinking = true
    var status = ""
    let engine = LocalAI()
    private var task: Task<Void, Never>?

    func ask(store: LibraryStore, modelURL: URL) {
        let question = String(draft.trimmed.prefix(3000))
        guard !question.isEmpty, !busy else { return }
        let previous = turns.last?.question
        let query = KnowledgeSearch.tokens(question).count < 4 ? question + " " + (previous ?? "") : question
        let sources = store.searchIndex.search(query, limit: 6, forAnswer: true).map(\.evidence)
        draft = ""
        let turn = ConversationTurn(question: question, sources: sources)
        turns.append(turn)
        guard !sources.isEmpty else { turns[turns.count - 1].error = "I couldn’t find a matching source. Try a procedure name, import a document, or confirm a relevant update."; return }
        busy = true
        status = "Reading \(sources.count) passages and preparing a cited answer…"
        task = Task {
            defer { busy = false; task = nil }
            do {
                let response = try await engine.answer(question: question, previous: previous, evidence: sources, modelURL: modelURL, think: thinking)
                try Task.checkCancellation()
                if let index = turns.firstIndex(where: { $0.id == turn.id }) { turns[index].response = response }
            } catch {
                if let index = turns.firstIndex(where: { $0.id == turn.id }) {
                    turns[index].error = error is CancellationError ? "Answer stopped. The matching sources are still available." : error.localizedDescription
                }
            }
        }
    }
    func cancel() { task?.cancel() }
    func clear() { task?.cancel(); turns = [] }
}

struct AssistantView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(ModelManager.self) private var models
    @Environment(ChatController.self) private var chat
    @State private var evidence: Evidence?
    @State private var note: KnowledgeNote?
    var body: some View {
        @Bindable var chat = chat
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if chat.turns.isEmpty {
                            PageHeading(title: "Ask. Check. Move forward.", subtitle: "Reason through a situation using the documents and confirmed updates on this device.")
                            Surface {
                                VStack(alignment: .leading, spacing: 14) {
                                    Label(models.installed ? "Local AI is ready" : "Local AI hasn’t been downloaded", systemImage: models.installed ? "checkmark.shield" : "arrow.down.circle").font(.headline)
                                    Text(models.installed ? "Answers use source passages from your knowledge base. Open a citation to inspect the original wording." : "Download the optional model in Settings. You can browse your knowledge and search for sources without it.").foregroundStyle(.secondary)
                                    Text("Try: “What conditions apply to this request?” or “Which steps should I follow in this situation?”").font(.callout)
                                }
                            }
                        }
                        ForEach(chat.turns) { turn in
                            VStack(alignment: .leading, spacing: 16) {
                                Text(turn.question).font(.title3.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(18).background(Brand.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 18))
                                if let answer = turn.response {
                                    if answer.uncertain { Label("Check the conditions and sources before using this answer.", systemImage: "exclamationmark.bubble").font(.callout).foregroundStyle(.orange) }
                                    if let overview = answer.overview { answerPart(overview, sources: answer.evidence) }
                                    if !answer.steps.isEmpty {
                                        Text("Suggested steps").font(.headline)
                                        ForEach(Array(answer.steps.enumerated()), id: \.offset) { index, part in
                                            HStack(alignment: .top, spacing: 14) { Text("\(index + 1)").bold().foregroundStyle(Brand.accent); answerPart(part, sources: answer.evidence) }
                                        }
                                    }
                                    if let wording = answer.suggestedWording { Surface { VStack(alignment: .leading, spacing: 10) { Text("Suggested wording").font(.headline); answerPart(wording, sources: answer.evidence) } } }
                                    if !answer.followUp.isEmpty { Label(answer.followUp, systemImage: "questionmark.bubble").foregroundStyle(Brand.accent) }
                                    if answer.withheldUnsupportedText { Text("Some generated text was withheld because its supporting quote could not be verified.").font(.caption).foregroundStyle(.secondary) }
                                    if answer.overview == nil && answer.steps.isEmpty && answer.followUp.isEmpty { Text("No supported answer was produced. Review the sources below.").foregroundStyle(.secondary) }
                                    Button { saveDraft(turn) } label: { Label("Save as draft update", systemImage: "square.and.pencil") }.buttonStyle(.bordered)
                                }
                                if let error = turn.error { Text(error).foregroundStyle(.secondary) }
                                if !turn.sources.isEmpty {
                                    DisclosureGroup("\(turn.sources.count) matching sources") {
                                        ForEach(turn.sources) { source in Button { evidence = source } label: { EvidenceCard(evidence: source) }.buttonStyle(.plain).padding(.top, 8) }
                                    }
                                }
                            }.id(turn.id)
                        }
                        if chat.busy { HStack { ProgressView(); Text(chat.status).font(.callout).foregroundStyle(.secondary) }.id("working") }
                    }.padding(22).frame(maxWidth: 950).frame(maxWidth: .infinity)
                }.onChange(of: chat.turns.count) { _, _ in if let last = chat.turns.last { withAnimation { proxy.scrollTo(last.id, anchor: .top) } } }
            }
            Divider()
            VStack(spacing: 10) {
                HStack { Label("On-device", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary); Spacer(); Toggle("More reasoning", isOn: $chat.thinking).font(.caption).fixedSize().disabled(chat.busy) }
                HStack(alignment: .bottom, spacing: 12) {
                    TextField("Describe your question or situation…", text: $chat.draft, axis: .vertical).lineLimit(1...5).textFieldStyle(.plain).padding(13)
                        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))
                    if chat.busy { Button { chat.cancel() } label: { Image(systemName: "stop.circle.fill").font(.largeTitle) }.accessibilityLabel("Stop answer") }
                    else { Button { chat.ask(store: store, modelURL: models.folder) } label: { Image(systemName: "arrow.up.circle.fill").font(.largeTitle) }.disabled(chat.draft.trimmed.isEmpty).accessibilityLabel("Ask") }
                }
                Text("Citations identify matching text; they do not guarantee the interpretation is correct. Chats are not saved between app launches.").font(.caption2).foregroundStyle(.secondary)
            }.padding(16).frame(maxWidth: 950).frame(maxWidth: .infinity).background(.bar)
        }.navigationTitle("Ask your knowledge")
            .toolbar { ToolbarItem(placement: .primaryAction) { Button("Clear chat") { chat.clear() }.disabled(chat.turns.isEmpty) } }
            .sheet(item: $evidence) { SourceDetail(evidence: $0) }
            .sheet(item: $note) { NoteEditor(note: $0) }
    }
    private func answerPart(_ part: AnswerPart, sources: [Evidence]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(part.text).textSelection(.enabled).lineSpacing(3)
            ForEach(Array(part.citations.enumerated()), id: \.offset) { _, citation in
                if citation.source > 0 && citation.source <= sources.count {
                    Button { evidence = sources[citation.source - 1] } label: {
                        Label("\(sources[citation.source - 1].title) · \(sources[citation.source - 1].location)", systemImage: "text.quote").font(.caption).multilineTextAlignment(.leading)
                    }
                }
            }
        }
    }
    private func saveDraft(_ turn: ConversationTurn) {
        guard let answer = turn.response else { return }
        let content = ([answer.overview?.text ?? ""] + answer.steps.map(\.text)).filter { !$0.isEmpty }.joined(separator: "\n\n")
        note = KnowledgeNote(title: String(turn.question.prefix(160)), text: content, source: "AI draft; review before confirming. Sources: " + turn.sources.map { $0.title + " (" + $0.location + ")" }.joined(separator: "; "))
    }
}
