import SwiftUI
import UniformTypeIdentifiers

struct OverviewView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(ChatController.self) private var chat
    @State private var query = ""
    @State private var note: KnowledgeNote?
    @State private var importing = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 18) {
                    Label("GUIDED ASSISTANCE", systemImage: "sparkle").font(.caption.weight(.bold)).tracking(1.4)
                    Text("A clearer answer.\nA source you can check.").font(.system(size: 32, weight: .bold, design: .rounded))
                    Text("Bring your documents, organize what matters, and keep your knowledge current.")
                        .foregroundStyle(.white.opacity(0.78))
                    HStack {
                        TextField("Ask about your documents…", text: $query).textFieldStyle(.plain).foregroundStyle(.primary)
                            .onSubmit { ask() }
                        Button(action: ask) { Image(systemName: "arrow.up.circle.fill").font(.title) }.disabled(query.trimmed.isEmpty)
                    }.padding(13).background(.background, in: RoundedRectangle(cornerRadius: 13))
                }.padding(26).frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(.white)
                    .background(LinearGradient(colors: [Brand.ink, Brand.accent.opacity(0.9)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 26))

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 12) {
                    metric("Documents", value: store.library.documents.count, icon: "doc.text")
                    metric("Confirmed updates", value: store.library.notes.filter { $0.state == .confirmed }.count, icon: "checkmark.seal")
                    metric("Request guides", value: store.library.guides.count, icon: "list.bullet.clipboard")
                }
                HStack {
                    Button { importing = true } label: { Label("Import documents", systemImage: "plus") }.buttonStyle(.borderedProminent)
                    Button { note = KnowledgeNote() } label: { Label("Add an update", systemImage: "square.and.pencil") }.buttonStyle(.bordered)
                }.controlSize(.large)

                if store.library.documents.isEmpty && store.library.notes.isEmpty {
                    Surface {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Make it yours").font(.title3.bold())
                            Label("Import PDFs, text files, or Markdown.", systemImage: "1.circle")
                            Label("Add request guides for the situations you handle often.", systemImage: "2.circle")
                            Label("Download the optional local AI when you’re ready to chat.", systemImage: "3.circle")
                            Text("Your files stay separate from the app’s source code. Nothing you import is sent to GitHub.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                if !store.importMessage.isEmpty { Label(store.importMessage, systemImage: "doc.badge.checkmark").font(.callout).foregroundStyle(.secondary) }
                let favorites = store.library.guides.filter(\.isFavorite)
                if !favorites.isEmpty {
                    Text("Pinned requests").font(.title2.bold())
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250))], spacing: 12) {
                        ForEach(favorites) { guide in NavigationLink { GuideDetail(guide: guide) } label: { GuideCard(guide: guide) }.buttonStyle(.plain) }
                    }
                }
                HStack { Text("Recent updates").font(.title2.bold()); Spacer(); Text("Effective dates matter").font(.caption).foregroundStyle(.secondary) }
                let updates = store.library.notes.sorted { $0.updatedAt > $1.updatedAt }.prefix(5)
                if updates.isEmpty { Text("New facts and procedure changes will appear here.").foregroundStyle(.secondary) }
                ForEach(Array(updates)) { update in
                    Button { note = update } label: { NoteCard(note: update) }.buttonStyle(.plain)
                }
            }.padding(22).frame(maxWidth: 1100).frame(maxWidth: .infinity)
        }
        .background(Color.secondary.opacity(0.04)).navigationTitle("Overview")
        .sheet(item: $note) { NoteEditor(note: $0) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .plainText, UTType(filenameExtension: "md") ?? .plainText], allowsMultipleSelection: true) {
            switch $0 { case .success(let urls): Task { await store.importDocuments(urls) }; case .failure(let error): store.errorMessage = error.localizedDescription }
        }
        .overlay { if store.isImporting { ProgressView(store.importMessage).padding(30).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20)) } }
    }
    private func metric(_ title: String, value: Int, icon: String) -> some View {
        Surface {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: icon).foregroundStyle(Brand.accent)
                Text("\(value)").font(.largeTitle.bold())
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func ask() { if !query.trimmed.isEmpty { chat.draft = query; query = ""; chat.requestedNavigation = true } }
}
