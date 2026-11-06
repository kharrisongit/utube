// Test-only storage checks; excluded from installable iPhone and Mac apps.
#if targetEnvironment(simulator) || GUIDED_STORAGE_CHECKS
import Foundation

enum SimulatorChecks {
    @MainActor static func run(store: LibraryStore) async {
        let report = store.root.appendingPathComponent("simulator-check.json")
        do {
            try store.commit(KnowledgeLibrary())
            var note = KnowledgeNote(title: "Equipment returns", text: "Return a loaned projector to the equipment desk within three business days.", source: "Fictional demonstration guide", state: .confirmed)
            try store.saveNote(note)
            note = store.library.notes[0]
            note.text = "Return a loaned projector to the equipment desk within five business days."
            try store.saveNote(note)
            try check(store.library.notes[0].revision == 2, "Note revisions")
            try check(store.library.notes[0].history.count == 1, "Note history")
            let draft = KnowledgeNote(title: "Draft reminder", text: "The unreviewed archiveword rule is not available for answers.")
            try store.saveNote(draft)
            try check(store.searchIndex.search("archiveword", forAnswer: true).isEmpty, "Draft exclusion")
            try store.saveGuide(RequestGuide(title: "Equipment checkout", topic: "Operations", summary: "Prepare an equipment request with the details needed for handoff.", questions: "Item number\nPickup date\nReturn date", steps: "Check availability.\nRecord the item number.\nConfirm the return date.", source: "Fictional demonstration guide", state: .confirmed, isFavorite: true))
            let imported = FileManager.default.temporaryDirectory.appendingPathComponent("Equipment-reference.txt")
            try Data("An equipment request includes an item number, a pickup date, and a planned return date.".utf8).write(to: imported)
            defer { try? FileManager.default.removeItem(at: imported) }
            await store.importDocuments([imported])
            try check(store.library.documents.count == 1, "Document import")
            try check(!store.searchIndex.search("pickup date").isEmpty, "Document search")
            let password = "simulator-only-example-passphrase"
            let backup = try await store.makeBackup(password: password)
            var rejected = false
            do { try await store.restoreBackup(backup, password: "incorrect-example-passphrase") }
            catch { rejected = true }
            try check(rejected && store.library.documents.count == 1, "Incorrect-passphrase preservation")
            let disposable = KnowledgeNote(title: "Temporary marker", text: "This marker must disappear after restoring the earlier snapshot.")
            try store.saveNote(disposable)
            try await store.restoreBackup(backup, password: password)
            try check(!store.library.notes.contains { $0.id == disposable.id }, "Backup restoration")
            let disk = try JSONDecoder().decode(KnowledgeLibrary.self, from: Data(contentsOf: store.stateFile))
            try check(disk.documents.count == 1 && disk.guides.count == 1, "Catalog persistence")
            try LibraryStore.writePrivate(Data("{\"status\":\"passed\",\"checks\":9}".utf8), to: report)
        } catch {
            let data = (try? JSONSerialization.data(withJSONObject: ["status": "failed", "error": error.localizedDescription])) ?? Data()
            try? LibraryStore.writePrivate(data, to: report)
        }
    }
    private static func check(_ result: Bool, _ name: String) throws {
        if !result { throw NSError(domain: "SimulatorCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
    }
}
#endif
