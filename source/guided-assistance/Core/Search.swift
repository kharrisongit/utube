import Foundation

struct Evidence: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var itemID: UUID
    var title: String
    var kind: String
    var page: Int?
    var text: String
    var provenance: String
    var effectiveAt: Date?
    var isEligible: Bool
    var location: String { page.map { "Page \($0)" } ?? provenance }
}

struct SearchHit: Identifiable, Sendable {
    var evidence: Evidence
    var score: Double
    var id: String { evidence.id }
}

struct KnowledgeSearch: Sendable {
    private(set) var passages: [Evidence]
    private var frequencies: [[String: Int]]
    private var documentFrequency: [String: Int]
    private var averageLength: Double = 1
    private var titles: [Set<String>]
    private var vocabulary: [String] = []

    init(library: KnowledgeLibrary, now: Date = Date()) {
        var result: [Evidence] = []
        for doc in library.documents {
            for page in doc.pages {
                for (index, part) in Self.chunk(page.text).enumerated() {
                    result.append(Evidence(id: "\(doc.id)-\(page.number)-\(index)", itemID: doc.id, title: doc.title,
                        kind: "document", page: page.number, text: part, provenance: doc.category,
                        effectiveAt: doc.effectiveAt, isEligible: doc.effectiveAt.map { Calendar.current.startOfDay(for: $0) <= Calendar.current.startOfDay(for: now) } ?? true))
                }
            }
        }
        for note in library.notes where note.state != .archived {
            for (index, part) in Self.chunk(note.text).enumerated() {
                result.append(Evidence(id: "\(note.id)-v\(note.revision)-\(index)", itemID: note.id, title: note.title,
                    kind: "note", page: nil, text: part,
                    provenance: "\(note.state.title) update · v\(note.revision)" + (note.source.isEmpty ? "" : " · \(note.source)"),
                    effectiveAt: note.effectiveAt, isEligible: note.eligible(at: now)))
            }
        }
        for guide in library.guides where guide.state != .archived {
            let text = [guide.summary, guide.questions, guide.steps, guide.wording].filter { !$0.isEmpty }.joined(separator: "\n")
            for (index, part) in Self.chunk(text).enumerated() {
                result.append(Evidence(id: "\(guide.id)-\(index)", itemID: guide.id, title: guide.title,
                    kind: "guide", page: nil, text: part, provenance: "\(guide.state.title) guide · \(guide.source)",
                    effectiveAt: nil, isEligible: guide.state == .confirmed))
            }
        }
        passages = result
        frequencies = result.map { Dictionary(Self.tokens($0.text).map { ($0, 1) }, uniquingKeysWith: +) }
        titles = result.map { Set(Self.tokens($0.title)) }
        documentFrequency = [:]
        for counts in frequencies {
            for word in counts.keys { documentFrequency[word, default: 0] += 1 }
        }
        vocabulary = documentFrequency.keys.sorted()
        averageLength = max(1, Double(frequencies.reduce(0) { $0 + $1.values.reduce(0, +) }) / Double(max(1, result.count)))
    }

    func search(_ query: String, limit: Int = 12, forAnswer: Bool = false) -> [SearchHit] {
        guard limit > 0 else { return [] }
        let terms = Array(Set(Self.tokens(query))).sorted()
        guard !terms.isEmpty else { return [] }
        let count = Double(max(1, passages.count))
        var alternatives: [String: [String]] = [:]
        for term in terms where term.count >= 5 && documentFrequency[term] == nil {
            alternatives[term] = Array(vocabulary.filter { Self.oneEditApart(term, $0) }.prefix(8))
        }
        var hits: [SearchHit] = []
        for index in passages.indices {
            let item = passages[index]
            if forAnswer && !item.isEligible { continue }
            let tf = frequencies[index]
            let length = Double(tf.values.reduce(0, +))
            var score = 0.0, matched = 0
            for term in terms {
                var f = Double(tf[term] ?? 0)
                let titleMatch = titles[index].contains(term)
                if f == 0 && !titleMatch, let candidates = alternatives[term] {
                    f = Double(candidates.map { tf[$0] ?? 0 }.max() ?? 0) * 0.35
                }
                if f > 0 || titleMatch {
                    matched += 1
                    let df = Double(documentFrequency[term] ?? 0)
                    let idf = log(1 + (count - df + 0.5) / (df + 0.5))
                    score += idf * (f * 2.2 / (f + 1.2 * (0.25 + 0.75 * length / averageLength)))
                    if titleMatch { score += idf * 1.8 }
                }
            }
            guard matched > 0 else { continue }
            score *= 0.3 + 0.7 * Double(matched) / Double(terms.count)
            hits.append(SearchHit(evidence: item, score: score))
        }
        hits.sort { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
        var selected: [SearchHit] = [], counts: [UUID: Int] = [:]
        for hit in hits {
            if counts[hit.evidence.itemID, default: 0] >= (forAnswer ? 2 : 5) { continue }
            selected.append(hit)
            counts[hit.evidence.itemID, default: 0] += 1
            if selected.count == limit { break }
        }
        return selected
    }

    static func chunk(_ text: String) -> [String] {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return [] }
        var parts: [String] = [], start = 0
        while start < words.count {
            let end = min(start + 220, words.count)
            parts.append(words[start..<end].joined(separator: " "))
            if end == words.count { break }
            start = end - 35
        }
        return parts
    }

    static let stop = Set("a an and are as at be been but by can could do does for from had has have how i if in is it its me my of on or our please should that the their them there these they this to was we what when where which who why will with would you your about need know help tell".split(separator: " ").map(String.init))
    static func tokens(_ text: String) -> [String] {
        text.normalized.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 && !stop.contains($0) }
    }
    static func oneEditApart(_ a: String, _ b: String) -> Bool {
        let x = Array(a), y = Array(b)
        guard abs(x.count - y.count) <= 1 else { return false }
        var i = 0, j = 0, edits = 0
        while i < x.count && j < y.count {
            if x[i] == y[j] { i += 1; j += 1; continue }
            edits += 1
            if edits > 1 { return false }
            if x.count >= y.count { i += 1 }
            if y.count >= x.count { j += 1 }
        }
        return edits + (x.count - i) + (y.count - j) <= 1
    }
}
