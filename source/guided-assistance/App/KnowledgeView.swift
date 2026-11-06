import SwiftUI
import UniformTypeIdentifiers
import PDFKit

struct KnowledgeView: View {
    @Environment(LibraryStore.self) private var store
    @State private var query = ""
    @State private var tab = "Documents"
    @State private var importing = false
    @State private var note: KnowledgeNote?
    @State private var source: Evidence?
    @State private var document: KnowledgeDocument?
    @State private var hits: [SearchHit] = []
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeading(title: "Your knowledge, organized.", subtitle: "Documents and updates you can find, review, and use.")
                Picker("View", selection: $tab) { Text("Documents").tag("Documents"); Text("Updates").tag("Updates") }.pickerStyle(.segmented)
                if !query.trimmed.isEmpty {
                    Text("\(hits.count) matching passages").font(.headline)
                    ForEach(hits) { hit in Button { source = hit.evidence } label: { EvidenceCard(evidence: hit.evidence) }.buttonStyle(.plain) }
                    if hits.isEmpty { ContentUnavailableView.search(text: query) }
                } else if tab == "Documents" {
                    if store.library.documents.isEmpty { ContentUnavailableView("Start with your documents", systemImage: "doc.badge.plus", description: Text("Import a PDF, text file, or Markdown document. No example work documents are bundled.")) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 270))], spacing: 14) {
                        ForEach(store.library.documents) { doc in
                            Button { document = doc } label: {
                                Surface {
                                    VStack(alignment: .leading, spacing: 12) {
                                        HStack { Image(systemName: "doc.text.fill").font(.title2).foregroundStyle(Brand.accent); Spacer(); if doc.isFavorite { Image(systemName: "star.fill").foregroundStyle(.orange) } }
                                        Text(doc.title).font(.headline).multilineTextAlignment(.leading)
                                        Text("\(doc.pageCount) pages · \(doc.category)").font(.caption).foregroundStyle(.secondary)
                                        if let effective = doc.effectiveAt { Text("Effective \(effective.formatted(date: .abbreviated, time: .omitted))").font(.caption) }
                                        else { Pill(text: "Effective date not set", color: .orange) }
                                        if doc.unreadablePages > 0 { Text("\(doc.unreadablePages) pages may need OCR").font(.caption).foregroundStyle(.orange) }
                                    }
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                } else {
                    if store.library.notes.isEmpty { ContentUnavailableView("Capture what changed", systemImage: "square.and.pencil", description: Text("Add a fact, effective date, and source. Confirm it when it is ready for the assistant.")) }
                    ForEach(store.library.notes.sorted { $0.updatedAt > $1.updatedAt }) { update in
                        Button { note = update } label: { NoteCard(note: update) }.buttonStyle(.plain)
                    }
                }
                if !store.importMessage.isEmpty { Text(store.importMessage).font(.callout).foregroundStyle(.secondary) }
            }.padding(22).frame(maxWidth: 1100).frame(maxWidth: .infinity)
        }.background(Color.secondary.opacity(0.04)).navigationTitle("Knowledge")
        .searchable(text: $query, prompt: "Search your knowledge")
        .task(id: "\(query)|\(store.library.updatedAt.timeIntervalSince1970)") {
            guard !query.trimmed.isEmpty else { hits = []; return }
            let input = query
            let index = store.searchIndex
            do {
                try await Task.sleep(for: .milliseconds(180))
                let matches = await Task.detached(priority: .userInitiated) { index.search(input, limit: 30) }.value
                try Task.checkCancellation()
                hits = matches
            } catch { }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { note = KnowledgeNote() } label: { Label("Add update", systemImage: "square.and.pencil") }
                Button { importing = true } label: { Label("Import", systemImage: "plus") }.disabled(store.isImporting)
            }
        }
        .sheet(item: $note) { NoteEditor(note: $0) }
        .sheet(item: $source) { SourceDetail(evidence: $0) }
        .sheet(item: $document) { DocumentDetail(document: $0) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .plainText, UTType(filenameExtension: "md") ?? .plainText], allowsMultipleSelection: true) {
            switch $0 { case .success(let urls): Task { await store.importDocuments(urls) }; case .failure(let error): store.errorMessage = error.localizedDescription }
        }
        .overlay { if store.isImporting { ProgressView(store.importMessage).padding(30).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20)) } }
    }
}

struct NoteCard: View {
    var note: KnowledgeNote
    var body: some View {
        Surface {
            VStack(alignment: .leading, spacing: 10) {
                HStack { Pill(text: note.state.title, color: note.state == .confirmed ? .green : .orange); Spacer(); Text("v\(note.revision)").font(.caption).foregroundStyle(.secondary) }
                Text(note.title).font(.headline)
                Text(note.text).font(.callout).foregroundStyle(.secondary).lineLimit(3).multilineTextAlignment(.leading)
                Text("\(note.topic) · Effective \(note.effectiveAt.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
struct EvidenceCard: View {
    var evidence: Evidence
    var body: some View {
        Surface {
            VStack(alignment: .leading, spacing: 10) {
                HStack { Image(systemName: evidence.kind == "document" ? "doc.text" : "text.badge.checkmark").foregroundStyle(Brand.accent); Text(evidence.title).font(.headline); Spacer() }
                Text(evidence.text).font(.callout).foregroundStyle(.secondary).lineLimit(4).multilineTextAlignment(.leading)
                HStack { Text(evidence.location).font(.caption).foregroundStyle(Brand.accent); if !evidence.isEligible { Pill(text: "Not used in answers", color: .orange) } }
            }
        }
    }
}
struct SourceDetail: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var evidence: Evidence
    @State private var showOriginal = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(evidence.title).font(.title2.bold())
                    Text(evidence.location).foregroundStyle(Brand.accent)
                    if let date = evidence.effectiveAt { Text("Effective \(date.formatted(date: .abbreviated, time: .omitted))").font(.caption) }
                    Text(evidence.provenance).font(.caption).foregroundStyle(.secondary)
                    Text(evidence.text).textSelection(.enabled).lineSpacing(5)
                    if evidence.kind == "document", let doc = store.library.documents.first(where: { $0.id == evidence.itemID }), doc.filename.lowercased().hasSuffix(".pdf") {
                        Button("Open original PDF") { showOriginal = true }.buttonStyle(.borderedProminent)
                    }
                }.padding(24)
            }.navigationTitle("Source passage")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .sheet(isPresented: $showOriginal) {
                    if let doc = store.library.documents.first(where: { $0.id == evidence.itemID }) {
                        PDFScreen(url: store.original(for: doc), page: evidence.page ?? 1)
                    }
                }
        }.frame(minWidth: sheetWidth, minHeight: 450)
    }
}

var sheetWidth: CGFloat? {
    #if os(macOS)
    620
    #else
    nil
    #endif
}
struct PDFScreen: View {
    @Environment(\.dismiss) private var dismiss
    var url: URL
    var page: Int = 1
    var body: some View {
        NavigationStack {
            NativePDF(url: url, page: page).navigationTitle("Original document")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.frame(minWidth: sheetWidth, minHeight: 550)
    }
}
#if os(iOS)
struct NativePDF: UIViewRepresentable {
    var url: URL; var page: Int
    func makeUIView(context: Context) -> PDFView { let view = PDFView(); configure(view); return view }
    func updateUIView(_ view: PDFView, context: Context) {}
    private func configure(_ view: PDFView) {
        view.document = PDFDocument(url: url); view.autoScales = true
        if let target = view.document?.page(at: max(0, page - 1)) { view.go(to: target) }
    }
}
#else
struct NativePDF: NSViewRepresentable {
    var url: URL; var page: Int
    func makeNSView(context: Context) -> PDFView { let view = PDFView(); configure(view); return view }
    func updateNSView(_ view: PDFView, context: Context) {}
    private func configure(_ view: PDFView) {
        view.document = PDFDocument(url: url); view.autoScales = true
        if let target = view.document?.page(at: max(0, page - 1)) { view.go(to: target) }
    }
}
#endif
