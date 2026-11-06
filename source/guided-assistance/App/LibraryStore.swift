import Foundation
import Observation
import PDFKit
import CryptoKit
import Darwin

@MainActor @Observable
final class LibraryStore {
    private(set) var library = KnowledgeLibrary()
    private(set) var ready = false
    var errorMessage: String?
    var importMessage = ""
    var isImporting = false
    let root: URL
    private(set) var searchIndex = KnowledgeSearch(library: KnowledgeLibrary())

    init(rootURL: URL? = nil) {
        root = rootURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GuidedAssistance", isDirectory: true)
        do {
            try Self.prepareDirectory(root)
            try Self.prepareDirectory(originals)
            if FileManager.default.fileExists(atPath: stateFile.path) {
                library = try JSONDecoder().decode(KnowledgeLibrary.self, from: Data(contentsOf: stateFile)).validated()
            }
            searchIndex = KnowledgeSearch(library: library)
            ready = true
        } catch {
            errorMessage = "Your saved knowledge could not be opened. It has not been overwritten. \(error.localizedDescription)"
        }
    }
    var originals: URL { root.appendingPathComponent("Originals", isDirectory: true) }
    var models: URL { root.appendingPathComponent("Models", isDirectory: true) }
    var stateFile: URL { root.appendingPathComponent("knowledge.json") }
    var topics: [String] {
        Array(Set(["General"] + library.notes.map(\.topic) + library.guides.map(\.topic) + library.documents.map(\.category))).sorted()
    }
    func original(for document: KnowledgeDocument) -> URL { originals.appendingPathComponent(document.originalName) }
    static func prepareDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        var folder = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
    }
    static func writePrivate(_ bytes: Data, to url: URL) throws {
        let staging = url.deletingLastPathComponent().appendingPathComponent(".write-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        #if os(iOS)
        try bytes.write(to: staging, options: .completeFileProtection)
        #else
        try bytes.write(to: staging)
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
        var file = staging
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try file.setResourceValues(values)
        // Same-directory POSIX rename is the final commit point. No fallible
        // metadata changes run after replacing the old catalog.
        guard Darwin.rename(staging.path, url.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
    func commit(_ updated: KnowledgeLibrary) throws {
        guard ready else { throw KnowledgeError.invalidBackup }
        var next = try updated.validated()
        next.updatedAt = Date()
        let bytes = try JSONEncoder().encode(next)
        try Self.writePrivate(bytes, to: stateFile)
        library = next
        searchIndex = KnowledgeSearch(library: next)
    }
    func refreshDates() { searchIndex = KnowledgeSearch(library: library) }
    func saveNote(_ note: KnowledgeNote) throws {
        var next = library
        try next.save(note)
        try commit(next)
    }
    func saveGuide(_ guide: RequestGuide) throws {
        guard !guide.title.trimmed.isEmpty else { throw KnowledgeError.emptyNote }
        var next = library, saved = guide
        saved.updatedAt = Date()
        if let index = next.guides.firstIndex(where: { $0.id == guide.id }) { next.guides[index] = saved }
        else { next.guides.insert(saved, at: 0) }
        try commit(next)
    }
    func deleteNote(_ id: UUID) throws {
        var next = library
        next.notes.removeAll { $0.id == id }
        try commit(next)
    }
    func deleteGuide(_ id: UUID) throws {
        var next = library
        next.guides.removeAll { $0.id == id }
        try commit(next)
    }
    func deleteDocument(_ id: UUID) throws {
        var next = library
        guard let doc = next.documents.first(where: { $0.id == id }) else { return }
        next.documents.removeAll { $0.id == id }
        try commit(next)
        let file = original(for: doc)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
    func saveDocument(_ document: KnowledgeDocument) throws {
        var next = library
        if let index = next.documents.firstIndex(where: { $0.id == document.id }) {
            next.documents[index] = document
            try commit(next)
        }
    }
    func importDocuments(_ urls: [URL]) async {
        guard !isImporting else { return }
        isImporting = true
        defer { isImporting = false }
        var failures: [String] = []
        var imported = 0, unreadable = 0
        for url in urls {
            importMessage = "Reading \(url.lastPathComponent)…"
            let allowed = url.startAccessingSecurityScopedResource()
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try Self.extract(url)
                }.value
                if library.documents.contains(where: { $0.digest == result.0.digest }) { throw KnowledgeError.duplicate }
                if let pdf = result.1 { try Self.writePrivate(pdf, to: original(for: result.0)) }
                var next = library
                next.documents.insert(result.0, at: 0)
                do { try commit(next) }
                catch { try? FileManager.default.removeItem(at: original(for: result.0)); throw error }
                imported += 1
                unreadable += result.0.unreadablePages
            } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            if allowed { url.stopAccessingSecurityScopedResource() }
        }
        importMessage = "Imported \(imported) document\(imported == 1 ? "" : "s")."
        if unreadable > 0 { importMessage += " \(unreadable) pages had little or no text. Scans need OCR before import." }
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n\n") }
    }

    nonisolated static func extract(_ url: URL) throws -> (KnowledgeDocument, Data?) {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 50 * 1024 * 1024 else {
            throw NSError(domain: "Import", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose a file smaller than 50 MB."])
        }
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        var pages: [PageText] = [], count = 1, unreadable = 0
        let isPDF = url.pathExtension.lowercased() == "pdf"
        if isPDF {
            guard let pdf = PDFDocument(data: data), !pdf.isLocked, pdf.pageCount <= 2000 else { throw KnowledgeError.noText }
            count = pdf.pageCount
            for index in 0..<count {
                let text = pdf.page(at: index)?.string?.trimmed ?? ""
                if text.count < 40 { unreadable += 1 }
                if !text.isEmpty { pages.append(PageText(number: index + 1, text: String(text.prefix(200000)))) }
            }
        } else {
            guard ["txt", "md", "markdown"].contains(url.pathExtension.lowercased()),
                  let text = String(data: data, encoding: .utf8), !text.trimmed.isEmpty else { throw KnowledgeError.noText }
            pages = KnowledgeSearch.chunk(text).enumerated().map { PageText(number: $0.offset + 1, text: $0.element) }
            count = pages.count
        }
        guard !pages.isEmpty, pages.contains(where: { $0.text.count >= 40 }) else { throw KnowledgeError.noText }
        return (KnowledgeDocument(title: url.deletingPathExtension().lastPathComponent, filename: url.lastPathComponent,
            digest: digest, pages: pages, pageCount: count, unreadablePages: unreadable), isPDF ? data : nil)
    }
}
