import Foundation

enum ReviewState: String, Codable, CaseIterable, Sendable {
    case draft, confirmed, archived
    var title: String { rawValue.capitalized }
}

struct PageText: Codable, Hashable, Sendable {
    var number: Int
    var text: String
}

struct KnowledgeDocument: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var title: String
    var filename: String
    var digest: String
    var category: String = "Reference"
    var importedAt = Date()
    var effectiveAt: Date?
    var pages: [PageText]
    var pageCount: Int
    var unreadablePages: Int
    var isFavorite = false
    var originalName: String { id.uuidString + ".pdf" }
}

struct NoteVersion: Codable, Hashable, Sendable {
    var revision: Int
    var title: String
    var text: String
    var source: String
    var effectiveAt: Date
    var state: ReviewState
    var changedAt: Date
}

struct KnowledgeNote: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var title = ""
    var text = ""
    var topic = "General"
    var source = ""
    var effectiveAt = Date()
    var state = ReviewState.draft
    var revision = 1
    var updatedAt = Date()
    var history: [NoteVersion] = []
    var isFavorite = false
    var snapshot: NoteVersion {
        NoteVersion(revision: revision, title: title, text: text, source: source,
                    effectiveAt: effectiveAt, state: state, changedAt: updatedAt)
    }
    func eligible(at now: Date) -> Bool {
        state == .confirmed && Calendar.current.startOfDay(for: effectiveAt) <= Calendar.current.startOfDay(for: now)
    }
}

struct RequestGuide: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var title = ""
    var topic = "General"
    var summary = ""
    var questions = ""
    var steps = ""
    var wording = ""
    var source = ""
    var searchTerms = ""
    var state = ReviewState.draft
    var updatedAt = Date()
    var isFavorite = false
}

struct KnowledgeLibrary: Codable, Sendable {
    var schemaVersion = 1
    var documents: [KnowledgeDocument] = []
    var notes: [KnowledgeNote] = []
    var guides: [RequestGuide] = []
    var updatedAt = Date()

    func validated() throws -> Self {
        guard schemaVersion == 1, documents.count <= 500, notes.count <= 10000, guides.count <= 1000 else {
            throw KnowledgeError.invalidBackup
        }
        let ids = documents.map(\.id) + notes.map(\.id) + guides.map(\.id)
        guard Set(ids).count == ids.count else { throw KnowledgeError.invalidBackup }
        guard documents.allSatisfy({ $0.pages.count <= 2000 && $0.pages.allSatisfy { $0.number > 0 && $0.text.count <= 200000 } }),
              notes.allSatisfy({ $0.text.count <= 100000 && $0.history.count <= 10000 }) else {
            throw KnowledgeError.invalidBackup
        }
        return self
    }

    mutating func save(_ note: KnowledgeNote) throws {
        guard !note.title.trimmed.isEmpty, !note.text.trimmed.isEmpty else { throw KnowledgeError.emptyNote }
        var saved = note
        saved.updatedAt = Date()
        if let index = notes.firstIndex(where: { $0.id == note.id }) {
            guard notes[index].revision == note.revision else { throw KnowledgeError.staleNote }
            saved.history = notes[index].history + [notes[index].snapshot]
            saved.revision = notes[index].revision + 1
            notes[index] = saved
        } else { notes.insert(saved, at: 0) }
        updatedAt = Date()
    }
}

enum KnowledgeError: LocalizedError {
    case invalidBackup, emptyNote, staleNote, noText, duplicate, modelUnavailable, noAnswer, missingOriginal, libraryChanged, backupTooLarge
    var errorDescription: String? {
        switch self {
        case .invalidBackup: return "This backup is invalid or comes from an unsupported app version."
        case .emptyNote: return "Add a title and the information you want to save."
        case .staleNote: return "This note changed while it was open. Reopen it before editing."
        case .noText: return "No readable text was found. Import a searchable PDF, text, or Markdown file."
        case .duplicate: return "This document is already in your knowledge base."
        case .modelUnavailable: return "Download the local model in Settings first. Search and guides work without it."
        case .noAnswer: return "The model did not produce a supported answer. Check the source passages or ask a more specific question."
        case .missingOriginal: return "The original PDF is missing. Reimport it before making a backup."
        case .libraryChanged: return "The knowledge base changed during this operation. Try again after finishing the other edit."
        case .backupTooLarge: return "This knowledge base is too large for a single backup in this version. The limit is 160 MB of PDF originals or a 300 MB encrypted file."
        }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var normalized: String {
        folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
