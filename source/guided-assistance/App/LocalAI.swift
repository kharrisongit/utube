import Foundation
import Observation
import CryptoKit
import MLX
import MLXLLM
import MLXVLM
import MLXLMCommon
import Tokenizers

actor LocalAI {
    private var model: ModelContainer?
    private var working = false
    private var unloadWhenIdle = false
    func unload() {
        if working { unloadWhenIdle = true }
        else if model != nil { model = nil; Memory.clearCache() }
    }
    func answer(question: String, previous: String?, evidence: [Evidence], modelURL: URL, think: Bool) async throws -> GroundedAnswer {
        guard !working else { throw KnowledgeError.noAnswer }
        working = true
        defer {
            working = false
            if unloadWhenIdle {
                if model != nil { model = nil; Memory.clearCache() }
                unloadWhenIdle = false
            }
        }
        guard FileManager.default.fileExists(atPath: modelURL.appendingPathComponent("ready.json").path) else {
            throw KnowledgeError.modelUnavailable
        }
        if model == nil {
            Memory.cacheLimit = 20 * 1024 * 1024
            // Local-directory loader has no downloader and cannot fetch a model from the network.
            model = try await loadModelContainer(from: modelURL, using: LocalTokenizerLoader())
        }
        guard let model else { throw KnowledgeError.modelUnavailable }
        let session = ChatSession(model, instructions: AnswerPrompt.instructions,
            generateParameters: GenerateParameters(maxTokens: think ? 3000 : 1700, maxKVSize: 8192,
                                                   temperature: 0.6, topP: 0.95, topK: 20),
            additionalContext: ["enable_thinking": think])
        var output = ""
        for try await piece in session.streamResponse(to: AnswerPrompt.make(question: question, previousQuestion: previous, evidence: evidence)) {
            try Task.checkCancellation()
            output += piece
            if output.count > 30000 { break }
        }
        let answer = try AnswerPrompt.parse(output)
        return GroundedAnswer.validate(answer, evidence: evidence)
    }
}

struct ModelManifest: Decodable {
    struct File: Decodable {
        struct LFS: Decodable { var sha256: String; var size: Int64 }
        var rfilename: String
        var lfs: LFS?
    }
    var sha: String
    var siblings: [File]
}

@MainActor @Observable
final class ModelManager {
    static let repository = "mlx-community/Qwen3.5-4B-4bit"
    var downloading = false
    var status = ""
    var fraction = 0.0
    var task: Task<Void, Never>?
    let folder: URL
    private(set) var installed = false
    init(root: URL) {
        folder = root.appendingPathComponent("Models/Qwen3.5-4B-4bit", isDirectory: true)
        installed = FileManager.default.fileExists(atPath: folder.appendingPathComponent("ready.json").path)
    }

    func remove() throws {
        guard !downloading else { return }
        try FileManager.default.removeItem(at: folder)
        installed = false
        status = "Model removed. Your knowledge base is unchanged."
    }

    func start() {
        guard !downloading, !installed else { return }
        downloading = true
        task = Task {
            defer { downloading = false; task = nil }
            do { try await download(); status = "Model ready. Chat now works offline." }
            catch is CancellationError { status = "Download canceled. You can retry later." }
            catch let error as URLError where error.code == .cancelled { status = "Download canceled. You can retry later." }
            catch { status = "Download failed: \(error.localizedDescription)" }
        }
    }
    func cancel() { task?.cancel() }
    private func download() async throws {
        status = "Finding the model files…"
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForResource = 7200
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let metadataURL = URL(string: "https://huggingface.co/api/models/\(Self.repository)?blobs=true")!
        let (metadata, response) = try await session.data(from: metadataURL)
        try Self.check(response)
        let manifest = try JSONDecoder().decode(ModelManifest.self, from: metadata)
        guard manifest.sha.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else { throw KnowledgeError.modelUnavailable }
        let files = manifest.siblings.filter { file in
            let name = file.rfilename
            return !name.contains("/") && !name.contains("..") && ["json", "safetensors", "jinja"].contains((name as NSString).pathExtension)
        }
        guard files.contains(where: { $0.rfilename == "config.json" }),
              files.contains(where: { $0.rfilename == "tokenizer.json" }),
              files.contains(where: { $0.rfilename.hasSuffix(".safetensors") }) else { throw KnowledgeError.modelUnavailable }
        let staging = folder.deletingLastPathComponent().appendingPathComponent("Download-\(UUID().uuidString)", isDirectory: true)
        try LibraryStore.prepareDirectory(staging)
        defer { try? FileManager.default.removeItem(at: staging) }
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            status = "Downloading \(file.rfilename) (\(index + 1)/\(files.count)). The weights are about 3 GB."
            fraction = Double(index) / Double(files.count)
            let url = URL(string: "https://huggingface.co/\(Self.repository)/resolve/\(manifest.sha)/\(file.rfilename)")!
            let (temporary, response) = try await session.download(from: url)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try Self.check(response)
            if let expected = file.lfs {
                let actual = try await Task.detached { try Self.digest(temporary) }.value
                guard actual.0 == expected.sha256, actual.1 == expected.size else {
                    throw NSError(domain: "Model", code: 1, userInfo: [NSLocalizedDescriptionKey: "A downloaded file did not pass its checksum. Try again."])
                }
            }
            try FileManager.default.copyItem(at: temporary, to: staging.appendingPathComponent(file.rfilename))
        }
        let marker = try JSONSerialization.data(withJSONObject: ["repository": Self.repository, "revision": manifest.sha])
        try LibraryStore.writePrivate(marker, to: staging.appendingPathComponent("ready.json"))
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        try FileManager.default.moveItem(at: staging, to: folder)
        installed = true
        fraction = 1
    }
    nonisolated private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
    nonisolated private static func digest(_ url: URL) throws -> (String, Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256(), count: Int64 = 0
        while let part = try handle.read(upToCount: 2 * 1024 * 1024), !part.isEmpty {
            hash.update(data: part)
            count += Int64(part.count)
        }
        return (hash.finalize().map { String(format: "%02x", $0) }.joined(), count)
    }
}
