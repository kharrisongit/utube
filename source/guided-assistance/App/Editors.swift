import SwiftUI

struct NoteEditor: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var note: KnowledgeNote
    @State private var confirmDelete = false
    @State private var error = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("Fact or update") {
                    TextField("Title", text: $note.title)
                    TextField("Topic", text: $note.topic)
                    TextEditor(text: $note.text).frame(minHeight: 160)
                }
                Section("Where it came from") {
                    TextField("Source, author, or reference", text: $note.source, axis: .vertical)
                    DatePicker("Effective date", selection: $note.effectiveAt, displayedComponents: .date)
                    Picker("Status", selection: $note.state) { ForEach(ReviewState.allCases, id: \.self) { Text($0.title).tag($0) } }
                    Text("Drafts and future-dated updates are not used in AI answers. Confirmed means you have reviewed it; it does not make the update official policy.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Favorite", isOn: $note.isFavorite)
                }
                if !note.history.isEmpty {
                    Section("Previous versions") {
                        ForEach(note.history.reversed(), id: \.revision) { version in
                            DisclosureGroup("Version \(version.revision) · \(version.changedAt.formatted(date: .abbreviated, time: .shortened))") {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(version.title).bold()
                                    Text(version.text).textSelection(.enabled)
                                    Text("\(version.state.title) · \(version.source)").font(.caption).foregroundStyle(.secondary)
                                }.padding(.vertical, 8)
                            }
                        }
                    }
                }
                if store.library.notes.contains(where: { $0.id == note.id }) {
                    Section { Button("Delete update and its history", role: .destructive) { confirmDelete = true } }
                }
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
            }.formStyle(.grouped).navigationTitle(note.revision > 1 ? "Edit update · v\(note.revision)" : "Knowledge update")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { do { try store.saveNote(note); dismiss() } catch { self.error = error.localizedDescription } }
                            .disabled(note.title.trimmed.isEmpty || note.text.trimmed.isEmpty)
                    }
                }
                .confirmationDialog("Delete this update and every saved revision?", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) { do { try store.deleteNote(note.id); dismiss() } catch { self.error = error.localizedDescription } }
                }
        }.frame(minWidth: sheetWidth, minHeight: 600)
    }
}

struct DocumentDetail: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var document: KnowledgeDocument
    @State private var showPDF = false
    @State private var confirmDelete = false
    @State private var error = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("Document") {
                    TextField("Title", text: $document.title)
                    TextField("Category", text: $document.category)
                    LabeledContent("Original file", value: document.filename)
                    LabeledContent("Pages", value: "\(document.pageCount)")
                    LabeledContent("Imported", value: document.importedAt.formatted(date: .abbreviated, time: .omitted))
                    Toggle("Favorite", isOn: $document.isFavorite)
                }
                Section("Currency") {
                    Toggle("Set an effective date", isOn: Binding(get: { document.effectiveAt != nil }, set: { document.effectiveAt = $0 ? Date() : nil }))
                    if document.effectiveAt != nil {
                        DatePicker("Effective", selection: Binding(get: { document.effectiveAt ?? Date() }, set: { document.effectiveAt = $0 }), displayedComponents: .date)
                    }
                    Text("Use the source’s actual effective date. An import date does not establish that a document is current. Future-dated documents are excluded from AI answers until that date.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Read") {
                    if document.filename.lowercased().hasSuffix(".pdf") { Button("Open original PDF") { showPDF = true } }
                    DisclosureGroup("Extracted text") {
                        ForEach(document.pages, id: \.number) { page in
                            VStack(alignment: .leading, spacing: 8) { Text("Page \(page.number)").font(.headline); Text(page.text).textSelection(.enabled) }.padding(.vertical, 8)
                        }
                    }
                    if document.unreadablePages > 0 { Text("\(document.unreadablePages) pages contained little or no extractable text. Image-only text is not indexed in this version.").foregroundStyle(.orange) }
                }
                Section { Button("Delete document", role: .destructive) { confirmDelete = true } }
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
            }.formStyle(.grouped).navigationTitle("Document details")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") { do { try store.saveDocument(document); dismiss() } catch { self.error = error.localizedDescription } } }
                }
                .sheet(isPresented: $showPDF) { PDFScreen(url: store.original(for: document)) }
                .confirmationDialog("Remove this document and its searchable passages?", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) { do { try store.deleteDocument(document.id); dismiss() } catch { self.error = error.localizedDescription } }
                }
        }.frame(minWidth: sheetWidth, minHeight: 600)
    }
}

struct GuideEditor: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var guide: RequestGuide
    @State private var error = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("Request type") {
                    TextField("Title", text: $guide.title)
                    TextField("Topic", text: $guide.topic)
                    TextField("When to use this guide", text: $guide.summary, axis: .vertical)
                    Toggle("Pin to overview", isOn: $guide.isFavorite)
                }
                Section("Details to collect — one per line") { TextEditor(text: $guide.questions).frame(minHeight: 90) }
                Section("Steps — one per line") { TextEditor(text: $guide.steps).frame(minHeight: 140) }
                Section("Suggested wording") { TextEditor(text: $guide.wording).frame(minHeight: 100) }
                Section("References") {
                    TextField("Source or reference", text: $guide.source, axis: .vertical)
                    TextField("Related search terms", text: $guide.searchTerms)
                    Picker("Status", selection: $guide.state) { ForEach(ReviewState.allCases, id: \.self) { Text($0.title).tag($0) } }
                    Text("Only confirmed guides can be used as sources for AI answers.").font(.caption).foregroundStyle(.secondary)
                }
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
            }.formStyle(.grouped).navigationTitle("Request guide")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") { do { try store.saveGuide(guide); dismiss() } catch { self.error = error.localizedDescription } }.disabled(guide.title.trimmed.isEmpty) }
                }
        }.frame(minWidth: sheetWidth, minHeight: 650)
    }
}
