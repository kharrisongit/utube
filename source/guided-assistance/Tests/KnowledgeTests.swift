import Foundation
import Testing
@testable import KnowledgeCore

private func document(_ title: String, _ text: String) -> KnowledgeDocument {
    KnowledgeDocument(title: title, filename: "fictional.txt", digest: "test-only",
                      pages: [PageText(number: 1, text: text)], pageCount: 1, unreadablePages: 0)
}

@Test func retrievalFindsRelevantPassages() {
    let returns = document("Equipment returns", "Return a loaned projector to the equipment desk within three business days.")
    let parking = document("Parking", "Visitor parking is available in the north lot after registration.")
    let index = KnowledgeSearch(library: KnowledgeLibrary(documents: [parking, returns]))
    #expect(index.search("projector return").first?.evidence.itemID == returns.id)
    #expect(index.search("projector return", limit: 0).isEmpty)
}

@Test func answersExcludeDraftArchivedAndFutureUpdates() {
    let now = Date(timeIntervalSince1970: 1800000000)
    var current = KnowledgeNote(title: "Equipment rule", text: "Equipment requests must include the item number.", effectiveAt: now, state: .confirmed)
    var draft = current; draft.id = UUID(); draft.state = .draft
    var future = current; future.id = UUID(); future.effectiveAt = now.addingTimeInterval(172800)
    var archived = current; archived.id = UUID(); archived.state = .archived
    current.source = "Fictional test procedure"
    let index = KnowledgeSearch(library: KnowledgeLibrary(notes: [current, draft, future, archived]), now: now)
    let answers = index.search("equipment", forAnswer: true)
    #expect(answers.count == 1)
    #expect(answers.first?.evidence.itemID == current.id)
    #expect(index.search("equipment").count == 3)
}

@Test func revisedNotesKeepHistoryButDoNotRetrieveOldText() throws {
    var library = KnowledgeLibrary()
    var note = KnowledgeNote(title: "Equipment", text: "The old service code is zephyrstone.", state: .confirmed)
    try library.save(note)
    note = library.notes[0]
    note.text = "The current service code is quartzfield."
    try library.save(note)
    #expect(library.notes[0].revision == 2)
    #expect(library.notes[0].history.count == 1)
    #expect(KnowledgeSearch(library: library).search("zephyrstone", forAnswer: true).isEmpty)
    #expect(!KnowledgeSearch(library: library).search("quartzfield", forAnswer: true).isEmpty)
    #expect(throws: KnowledgeError.self) { try library.save(note) }
}

@Test func retrievalPreservesPotentiallyConflictingSources() {
    let a = document("Equipment policy A", "Projector loans last three business days.")
    let b = document("Equipment policy B", "Projector loans last five business days.")
    let hits = KnowledgeSearch(library: KnowledgeLibrary(documents: [a, b])).search("projector loans", forAnswer: true)
    #expect(Set(hits.map(\.evidence.itemID)) == Set([a.id, b.id]))
}

@Test func futureDatedDocumentsAndDraftGuidesAreExcluded() {
    let now = Date()
    var future = document("Equipment", "Projector loans last three business days.")
    future.effectiveAt = now.addingTimeInterval(172800)
    let guide = RequestGuide(title: "Projector", summary: "Collect the item number before approving a projector request.")
    let index = KnowledgeSearch(library: KnowledgeLibrary(documents: [future], guides: [guide]), now: now)
    #expect(index.search("projector", forAnswer: true).isEmpty)
    #expect(index.search("projector").count == 2)
}

@Test func fabricatedCitationsAreWithheld() {
    let doc = document("Equipment", "Return the projector within three business days.")
    let evidence = KnowledgeSearch(library: KnowledgeLibrary(documents: [doc])).search("projector").map(\.evidence)
    let valid = AnswerPart(text: "Return it within three business days.", citations: [ModelCitation(source: 1, quote: "within three business days")])
    let invented = AnswerPart(text: "Keep it permanently.", citations: [ModelCitation(source: 1, quote: "keep it permanently")])
    let outOfRange = AnswerPart(text: "Ask the equipment desk.", citations: [ModelCitation(source: 99, quote: "within three business days")])
    let response = GroundedAnswer.validate(ModelAnswer(answer: valid, steps: [invented, outOfRange], suggestedWording: AnswerPart(text: "", citations: []), followUp: "", uncertain: false), evidence: evidence)
    #expect(response.overview != nil)
    #expect(response.steps.isEmpty)
    #expect(response.uncertain)
    #expect(response.withheldUnsupportedText)
}

@Test func parserHandlesReasoningEnvelopeWithoutExposingIt() throws {
    let raw = """
    <think>Private generated reasoning</think>
    ```json
    {"answer":{"text":"","citations":[]},"steps":[],"suggestedWording":{"text":"","citations":[]},"followUp":"Which item?","uncertain":true}
    ```
    """
    let result = try AnswerPrompt.parse(raw)
    #expect(result.followUp == "Which item?")
    #expect(result.uncertain)
}

@Test func invalidCatalogsCannotReplaceSavedKnowledge() throws {
    var library = KnowledgeLibrary()
    library.schemaVersion = 999
    #expect(throws: KnowledgeError.self) { try library.validated() }
    let note = KnowledgeNote(title: "Example", text: "Fictional test content")
    library = KnowledgeLibrary(notes: [note, note])
    #expect(throws: KnowledgeError.self) { try library.validated() }
}
