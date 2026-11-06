import Foundation
import CryptoKit
import CommonCrypto
import Security

struct BackupPayload: Codable, Sendable {
    var library: KnowledgeLibrary
    var pdfs: [String: Data]
}
struct SealedBackup: Codable, Sendable {
    var version = 1
    var salt: Data
    var sealed: Data
}
enum EncryptedBackup {
    static func key(password: String, salt: Data) throws -> SymmetricKey {
        guard password.count >= 12, salt.count == 16 else {
            throw NSError(domain: "Backup", code: 1, userInfo: [NSLocalizedDescriptionKey: "Use a backup passphrase of at least 12 characters."])
        }
        let passwordBytes = Array(password.utf8)
        var output = [UInt8](repeating: 0, count: 32)
        let result = passwordBytes.withUnsafeBytes { p in
            salt.withUnsafeBytes { s in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), p.baseAddress!.assumingMemoryBound(to: Int8.self),
                    passwordBytes.count, s.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 400000, &output, 32)
            }
        }
        guard result == kCCSuccess else { throw KnowledgeError.invalidBackup }
        return SymmetricKey(data: output)
    }
    static func seal(_ payload: BackupPayload, password: String) throws -> Data {
        var salt = Data(count: 16)
        let result = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard result == errSecSuccess else { throw KnowledgeError.invalidBackup }
        let bytes = try JSONEncoder().encode(payload)
        let box = try AES.GCM.seal(bytes, using: key(password: password, salt: salt))
        guard let combined = box.combined else { throw KnowledgeError.invalidBackup }
        let serialized = try JSONEncoder().encode(SealedBackup(salt: salt, sealed: combined))
        guard serialized.count <= 300 * 1024 * 1024 else { throw KnowledgeError.backupTooLarge }
        return serialized
    }
    static func open(_ data: Data, password: String) throws -> BackupPayload {
        guard data.count <= 300 * 1024 * 1024 else { throw KnowledgeError.invalidBackup }
        let envelope = try JSONDecoder().decode(SealedBackup.self, from: data)
        guard envelope.version == 1, envelope.salt.count == 16 else { throw KnowledgeError.invalidBackup }
        let decrypted = try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.sealed),
                                        using: key(password: password, salt: envelope.salt))
        let payload = try JSONDecoder().decode(BackupPayload.self, from: decrypted)
        _ = try payload.library.validated()
        let expected = Set(payload.library.documents.filter { $0.filename.lowercased().hasSuffix(".pdf") }.map(\.originalName))
        guard Set(payload.pdfs.keys) == expected else { throw KnowledgeError.invalidBackup }
        for doc in payload.library.documents where expected.contains(doc.originalName) {
            guard let pdf = payload.pdfs[doc.originalName], pdf.starts(with: Data("%PDF-".utf8)),
                  SHA256.hash(data: pdf).map({ String(format: "%02x", $0) }).joined() == doc.digest else {
                throw KnowledgeError.invalidBackup
            }
        }
        return payload
    }
}

extension LibraryStore {
    func makeBackup(password: String) async throws -> Data {
        let snapshot = library
        let directory = originals
        return try await Task.detached {
            var pdfs: [String: Data] = [:]
            var totalBytes = 0
            for doc in snapshot.documents where doc.filename.lowercased().hasSuffix(".pdf") {
                let file = directory.appendingPathComponent(doc.originalName)
                guard FileManager.default.fileExists(atPath: file.path) else { throw KnowledgeError.missingOriginal }
                totalBytes += try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard totalBytes <= 160 * 1024 * 1024 else { throw KnowledgeError.backupTooLarge }
                pdfs[doc.originalName] = try Data(contentsOf: file)
            }
            return try EncryptedBackup.seal(BackupPayload(library: snapshot, pdfs: pdfs), password: password)
        }.value
    }
    func restoreBackup(_ bytes: Data, password: String) async throws {
        let startingRevision = library.updatedAt
        let payload = try await Task.detached { try EncryptedBackup.open(bytes, password: password) }.value
        guard library.updatedAt == startingRevision else { throw KnowledgeError.libraryChanged }
        // New identifiers let old and restored originals coexist until the atomic
        // catalog write. An interrupted restore cannot remove the current PDFs.
        var restored = payload.library
        let previousFiles = library.documents.map { original(for: $0) }
        var written: [URL] = []
        do {
            for index in restored.documents.indices {
                let previousName = restored.documents[index].originalName
                restored.documents[index].id = UUID()
                if let bytes = payload.pdfs[previousName] {
                    let destination = original(for: restored.documents[index])
                    try Self.writePrivate(bytes, to: destination)
                    written.append(destination)
                }
            }
            try commit(restored)
        } catch {
            for file in written { try? FileManager.default.removeItem(at: file) }
            throw error
        }
        for file in previousFiles { try? FileManager.default.removeItem(at: file) }
    }
}
