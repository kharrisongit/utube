import Foundation

@main
struct StorageCheckRunner {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GuidedStorageCheck-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        await SimulatorChecks.run(store: store)
        let bytes = try Data(contentsOf: root.appendingPathComponent("simulator-check.json"))
        let report = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        guard report?["status"] as? String == "passed" else {
            throw NSError(domain: "StorageCheck", code: 1, userInfo: [
                NSLocalizedDescriptionKey: String(data: bytes, encoding: .utf8) ?? "Storage checks failed."])
        }
        try bytes.write(to: URL(fileURLWithPath: "build/native-storage-check.json"))
        print("Native storage checks passed: import, search, revisions, encrypted backup, and persistence.")
    }
}
