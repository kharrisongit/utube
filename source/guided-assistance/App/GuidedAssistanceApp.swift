import SwiftUI
import LocalAuthentication

@main
struct GuidedAssistanceApp: App {
    @State private var store: LibraryStore
    @State private var models: ModelManager
    @State private var chat = ChatController()
    init() {
        let library = LibraryStore()
        _store = State(initialValue: library)
        _models = State(initialValue: ModelManager(root: library.root))
    }
    var body: some Scene {
        WindowGroup {
            AppRoot().environment(store).environment(models).environment(chat)
                .tint(Brand.accent)
                .frame(minWidth: minimumWidth, minHeight: minimumHeight)
        }
    }
    private var minimumWidth: CGFloat? {
        #if os(macOS)
        return 880
        #else
        return nil
        #endif
    }
    private var minimumHeight: CGFloat? {
        #if os(macOS)
        return 650
        #else
        return nil
        #endif
    }
}

enum SectionID: String, CaseIterable, Identifiable {
    case home = "Overview", guides = "Requests", knowledge = "Knowledge", chat = "Ask", settings = "Settings"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .home: return "square.grid.2x2"
        case .guides: return "list.bullet.clipboard"
        case .knowledge: return "books.vertical"
        case .chat: return "bubble.left.and.bubble.right"
        case .settings: return "slider.horizontal.3"
        }
    }
}
enum Brand {
    static let accent = Color(red: 0.28, green: 0.40, blue: 0.90)
    static let ink = Color(red: 0.08, green: 0.12, blue: 0.23)
}

struct AppRoot: View {
    @Environment(LibraryStore.self) private var store
    @Environment(ChatController.self) private var chat
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("requireUnlock") private var requireUnlock = false
    @State private var unlocked = false
    @State private var unlockMessage = ""
    @State private var selected: SectionID? = .home
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        @Bindable var store = store
        Group {
            if requireUnlock && !unlocked {
                VStack(spacing: 20) {
                    Image(systemName: "lock.shield").font(.system(size: 56)).foregroundStyle(Brand.accent)
                    Text("Your knowledge, protected.").font(.title2.bold())
                    Button("Unlock Guided Assistance") { Task { await unlock() } }.buttonStyle(.borderedProminent)
                    if !unlockMessage.isEmpty { Text(unlockMessage).font(.callout).foregroundStyle(.secondary) }
                }.padding(32)
            } else if !store.ready {
                ContentUnavailableView("Knowledge could not be opened", systemImage: "externaldrive.badge.exclamationmark",
                    description: Text(store.errorMessage ?? "Restart the app. Your stored files have not been overwritten."))
            } else { navigation }
        }
        .overlay {
            if requireUnlock && scenePhase != .active {
                Rectangle().fill(.background).ignoresSafeArea()
                    .overlay { Image(systemName: "lock.shield").font(.largeTitle).foregroundStyle(Brand.accent) }
            }
        }
        .task { if requireUnlock { await unlock() } }
        .task {
            #if targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--smoke-test") {
                await SimulatorChecks.run(store: store)
            }
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.refreshDates() }
            if phase == .background {
                unlocked = false
                chat.cancel()
                Task { await chat.engine.unload() }
            }
        }
        .onChange(of: chat.requestedNavigation) { _, value in if value { selected = .chat; chat.requestedNavigation = false } }
        .alert("Something needs attention", isPresented: Binding(get: { store.ready && store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }

    @ViewBuilder private var navigation: some View {
        #if os(iOS)
        if sizeClass == .compact {
            TabView(selection: Binding(get: { selected ?? .home }, set: { selected = $0 })) {
                ForEach(SectionID.allCases) { section in
                    NavigationStack { page(section) }.tabItem { Label(section.rawValue, systemImage: section.icon) }.tag(section)
                }
            }
        } else { splitView }
        #else
        splitView
        #endif
    }
    private var splitView: some View {
        NavigationSplitView {
            List(selection: $selected) {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "square.stack.3d.up.fill").font(.largeTitle).foregroundStyle(Brand.accent)
                    Text("Guided\nAssistance").font(.title2.bold())
                    Text("YOUR PRIVATE REFERENCE").font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
                }.padding(.vertical, 18).listRowBackground(Color.clear)
                ForEach(SectionID.allCases) { section in
                    Label(section.rawValue, systemImage: section.icon).tag(section)
                }
                Section {
                    Label("Stored on this device", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
                }
            }.navigationSplitViewColumnWidth(min: 210, ideal: 235, max: 280)
        } detail: { NavigationStack { page(selected ?? .home) } }
    }
    @ViewBuilder private func page(_ section: SectionID) -> some View {
        switch section {
        case .home: OverviewView()
        case .guides: GuidesView()
        case .knowledge: KnowledgeView()
        case .chat: AssistantView()
        case .settings: SettingsView()
        }
    }
    private func unlock() async {
        do {
            let context = LAContext()
            unlocked = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Open your private knowledge base.")
            unlockMessage = ""
        } catch { unlockMessage = "Unlock with your device passcode or biometric authentication to continue." }
    }
}

struct Surface<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.primary.opacity(0.07), lineWidth: 1))
    }
}
struct Pill: View {
    var text: String
    var color: Color = Brand.accent
    var body: some View {
        Text(text).font(.caption.weight(.medium)).padding(.horizontal, 9).padding(.vertical, 5)
            .foregroundStyle(color).background(color.opacity(0.1), in: Capsule())
    }
}
struct PageHeading: View {
    var title: String
    var subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 30, weight: .bold, design: .rounded))
            Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
