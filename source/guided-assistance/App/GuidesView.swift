import SwiftUI

struct GuidesView: View {
    @Environment(LibraryStore.self) private var store
    @State private var editing: RequestGuide?
    @State private var query = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeading(title: "Familiar requests. Clear steps.", subtitle: "Build reusable guides for the situations you handle most.")
                if store.library.guides.isEmpty {
                    Surface {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Create your first request guide").font(.title3.bold())
                            Text("Give it a name, add the details to collect, list the steps, and link the supporting reference. The app ships without organization-specific procedures.").foregroundStyle(.secondary)
                            Button("New request guide") { editing = RequestGuide() }.buttonStyle(.borderedProminent)
                        }
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 270))], spacing: 14) {
                    ForEach(store.library.guides.filter { query.isEmpty || ($0.title + " " + $0.topic + " " + $0.summary).localizedCaseInsensitiveContains(query) }) { guide in
                        NavigationLink { GuideDetail(guide: guide) } label: { GuideCard(guide: guide) }.buttonStyle(.plain)
                    }
                }
            }.padding(22).frame(maxWidth: 1100).frame(maxWidth: .infinity)
        }.background(Color.secondary.opacity(0.04)).navigationTitle("Requests")
            .searchable(text: $query, prompt: "Find a request guide")
            .toolbar { ToolbarItem(placement: .primaryAction) { Button { editing = RequestGuide() } label: { Label("New guide", systemImage: "plus") } } }
            .sheet(item: $editing) { GuideEditor(guide: $0) }
    }
}
struct GuideCard: View {
    var guide: RequestGuide
    var body: some View {
        Surface {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Image(systemName: "list.bullet.clipboard.fill").font(.title2).foregroundStyle(Brand.accent); Spacer(); if guide.isFavorite { Image(systemName: "star.fill").foregroundStyle(.orange) } }
                Text(guide.title).font(.headline).multilineTextAlignment(.leading)
                Text(guide.summary.isEmpty ? "Add the details, steps, and references for this request." : guide.summary).font(.callout).foregroundStyle(.secondary).lineLimit(3).multilineTextAlignment(.leading)
                HStack { Pill(text: guide.topic); Pill(text: guide.state.title, color: guide.state == .confirmed ? .green : .orange) }
            }
        }
    }
}
struct GuideDetail: View {
    @Environment(LibraryStore.self) private var store
    @Environment(ChatController.self) private var chat
    @Environment(\.dismiss) private var dismiss
    var guide: RequestGuide
    @State private var checked: Set<Int> = []
    @State private var editing: RequestGuide?
    @State private var evidence: Evidence?
    @State private var confirmDelete = false
    private var current: RequestGuide { store.library.guides.first { $0.id == guide.id } ?? guide }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeading(title: current.title, subtitle: current.summary)
                HStack { Pill(text: current.topic); Pill(text: current.state.title, color: current.state == .confirmed ? .green : .orange) }
                if !current.questions.isEmpty {
                    Surface {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Details to collect").font(.title3.bold())
                            ForEach(Array(lines(current.questions).enumerated()), id: \.offset) { index, line in
                                Button { if checked.contains(index) { checked.remove(index) } else { checked.insert(index) } } label: {
                                    Label(line, systemImage: checked.contains(index) ? "checkmark.circle.fill" : "circle").frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.plain).foregroundStyle(checked.contains(index) ? Brand.accent : .primary)
                            }
                            Text("Checklist progress lasts for this visit.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if !current.steps.isEmpty {
                    Surface {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("What to do").font(.title3.bold())
                            ForEach(Array(lines(current.steps).enumerated()), id: \.offset) { index, line in
                                HStack(alignment: .top, spacing: 12) { Text("\(index + 1)").bold().foregroundStyle(Brand.accent); Text(line).textSelection(.enabled) }
                            }
                        }
                    }
                }
                if !current.wording.isEmpty { Surface { VStack(alignment: .leading, spacing: 12) { Text("Suggested wording").font(.title3.bold()); Text(current.wording).textSelection(.enabled) } } }
                if !current.source.isEmpty { Label(current.source, systemImage: "link").font(.callout).foregroundStyle(.secondary) }
                Button { chat.draft = "Help me with: \(current.title). "; chat.requestedNavigation = true } label: { Label("Ask about this request", systemImage: "bubble.left.and.bubble.right") }.buttonStyle(.borderedProminent)
                Text("Related sources").font(.title2.bold())
                let hits = store.searchIndex.search(current.searchTerms.isEmpty ? current.title : current.searchTerms, limit: 5).filter { $0.evidence.itemID != current.id }
                ForEach(hits) { hit in Button { evidence = hit.evidence } label: { EvidenceCard(evidence: hit.evidence) }.buttonStyle(.plain) }
                if hits.isEmpty { Text("Import relevant documents or add search terms to this guide.").foregroundStyle(.secondary) }
            }.padding(22).frame(maxWidth: 950).frame(maxWidth: .infinity)
        }.background(Color.secondary.opacity(0.04)).navigationTitle("Request guide")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Edit") { editing = current }
                    Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                }
            }
            .sheet(item: $editing) { GuideEditor(guide: $0) }
            .sheet(item: $evidence) { SourceDetail(evidence: $0) }
            .confirmationDialog("Delete this request guide?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { do { try store.deleteGuide(current.id); dismiss() } catch { store.errorMessage = error.localizedDescription } }
            }
    }
    private func lines(_ text: String) -> [String] { text.components(separatedBy: .newlines).map(\.trimmed).filter { !$0.isEmpty } }
}
