import SwiftUI
import UniformTypeIdentifiers
import LocalAuthentication

struct SettingsView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(ModelManager.self) private var models
    @Environment(ChatController.self) private var chat
    @AppStorage("requireUnlock") private var requireUnlock = false
    @State private var showBackup = false
    @State private var showDownload = false
    @State private var showRemoveModel = false
    @State private var message = ""
    var body: some View {
        Form {
            Section {
                Label("Guided Assistance", systemImage: "square.stack.3d.up.fill").font(.title2.bold())
                Text("A private document knowledge base with optional on-device AI.").foregroundStyle(.secondary)
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")
            }
            Section("Local AI") {
                LabeledContent("Model", value: "Qwen3.5 4B · 4-bit")
                LabeledContent("Status", value: models.installed ? "Installed on this device" : "Not downloaded")
                Text("The optional model download is approximately 3 GB. It needs additional working memory while answering. Performance and reliability must be tested on your device.")
                    .font(.callout).foregroundStyle(.secondary)
                if models.downloading {
                    ProgressView(value: models.fraction)
                    Text(models.status).font(.caption)
                    Button("Cancel download", role: .cancel) { models.cancel() }
                } else if !models.installed {
                    Button("Download local AI") { showDownload = true }.disabled(chat.busy)
                } else {
                    Button("Release AI from memory") { Task { await chat.engine.unload(); message = "The model can reload the next time you ask a question." } }.disabled(chat.busy)
                    Button("Remove downloaded model", role: .destructive) { showRemoveModel = true }.disabled(chat.busy)
                }
                if !models.status.isEmpty && !models.downloading { Text(models.status).font(.caption).foregroundStyle(.secondary) }
                Text("Only the model-download action contacts Hugging Face. Document import, search, and chat use local files. There is no cloud AI fallback.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Privacy") {
                Toggle("Require device authentication", isOn: Binding(get: { requireUnlock }, set: { enabled in
                    if enabled {
                        let context = LAContext()
                        var error: NSError?
                        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) { requireUnlock = true }
                        else { message = "Set up a device passcode or biometric authentication first." }
                    } else { requireUnlock = false }
                }))
                Text("Imported files live in this app’s private Application Support folder, separate from its source code. The knowledge folder is excluded from automatic device backups. Use an encrypted export for a backup or transfer.").font(.caption).foregroundStyle(.secondary)
                Text("No analytics, GitHub integration, account system, or automatic cloud synchronization is included. On Mac, disk encryption is controlled by your FileVault settings.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Backup and transfer") {
                Button("Encrypted export or restore") { showBackup = true }.disabled(store.isImporting || chat.busy)
                Text("Transfer an encrypted backup with AirDrop to use the same knowledge on another device. Restore replaces that device’s knowledge base; it does not merge edits.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Using your references") {
                Text("Confirm updates after reviewing them. Add effective dates and source names. Keep source documents current, and check the cited passage before relying on generated advice.")
                Text("PDF, UTF-8 text, and Markdown imports are supported. This preview extracts PDF text; scanned pages need OCR before import.").font(.caption).foregroundStyle(.secondary)
            }
            if !message.isEmpty { Section { Text(message).foregroundStyle(.secondary) } }
        }.formStyle(.grouped).navigationTitle("Settings")
            .sheet(isPresented: $showBackup) { BackupView() }
            .confirmationDialog("Download approximately 3 GB from Hugging Face?", isPresented: $showDownload, titleVisibility: .visible) {
                Button("Download model") { models.start() }
            } message: { Text("Use Wi-Fi and keep the app open. Your documents are not part of this request.") }
            .confirmationDialog("Remove the model from this device?", isPresented: $showRemoveModel, titleVisibility: .visible) {
                Button("Remove model", role: .destructive) {
                    Task {
                        await chat.engine.unload()
                        do { try FileManager.default.removeItem(at: models.folder); models.status = "Model removed. Your knowledge base is unchanged." }
                        catch { message = error.localizedDescription }
                    }
                }
            }
    }
}

struct VaultFile: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var data = Data()
    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct BackupView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(ChatController.self) private var chat
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirmation = ""
    @State private var mode = "Export"
    @State private var busy = false
    @State private var message = ""
    @State private var exporting = false
    @State private var importing = false
    @State private var confirmRestore = false
    @State private var file = VaultFile()
    @State private var restoreBytes: Data?
    var body: some View {
        NavigationStack {
            Form {
                Picker("Action", selection: $mode) { Text("Export").tag("Export"); Text("Restore").tag("Restore") }.pickerStyle(.segmented)
                Section("Backup passphrase") {
                    SecureField("At least 12 characters", text: $password)
                    if mode == "Export" { SecureField("Confirm passphrase", text: $confirmation) }
                    Text("Keep this passphrase somewhere safe. There is no recovery service. The encrypted file includes your documents, guides, and updates, but not the AI model.").font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    if mode == "Export" {
                        Button("Create encrypted backup") {
                            busy = true; message = "Encrypting your knowledge…"
                            Task {
                                defer { busy = false }
                                do { file = VaultFile(data: try await store.makeBackup(password: password)); exporting = true; message = "Choose where to save the encrypted backup." }
                                catch { message = error.localizedDescription }
                            }
                        }.disabled(password.count < 12 || password != confirmation)
                    } else {
                        Button("Choose encrypted backup") { importing = true }.disabled(password.count < 12)
                        Text("Restoring replaces this device’s current knowledge. Export a backup first if you want to keep it.").font(.caption).foregroundStyle(.orange)
                    }
                }
                if busy { ProgressView() }
                if !message.isEmpty { Text(message).foregroundStyle(.secondary) }
            }.disabled(busy).formStyle(.grouped).navigationTitle("Encrypted backup")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(busy) } }
                .fileExporter(isPresented: $exporting, document: file, contentType: .data, defaultFilename: "GuidedAssistance.gavault") { result in
                    switch result { case .success: message = "Encrypted backup saved."; case .failure(let error): message = error.localizedDescription }
                    file = VaultFile()
                }
                .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
                    do {
                        let url = try result.get()
                        let access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard size <= 300 * 1024 * 1024 else { throw KnowledgeError.invalidBackup }
                        restoreBytes = try Data(contentsOf: url)
                        confirmRestore = true
                    } catch { message = error.localizedDescription }
                }
                .confirmationDialog("Replace this device’s knowledge with the backup?", isPresented: $confirmRestore, titleVisibility: .visible) {
                    Button("Restore and replace", role: .destructive) {
                        guard let bytes = restoreBytes else { return }
                        busy = true; message = "Verifying and restoring…"
                        Task {
                            defer { busy = false; restoreBytes = nil }
                            do { try await store.restoreBackup(bytes, password: password); chat.clear(); message = "Backup restored." }
                            catch { message = "Restore failed. Check the passphrase and backup. Your existing knowledge was kept. \(error.localizedDescription)" }
                        }
                    }
                }
        }.frame(minWidth: sheetWidth, minHeight: 480)
    }
}
