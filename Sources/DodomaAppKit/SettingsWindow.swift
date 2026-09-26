import AppKit
import DodomaCore
import SwiftUI
import UniformTypeIdentifiers

/// One row of the per-app policy table.
///
/// The name and the icon are resolved once, when the settings change, rather
/// than inside `body`: LaunchServices lookups are cached but not free, and a
/// SwiftUI list re-evaluates its rows far more often than the settings change.
struct AppPolicyRow: Identifiable, Equatable {
    var id: String { bundleID }
    let bundleID: String
    let name: String
    let icon: NSImage?
    let policy: AppPolicy

    static func == (lhs: AppPolicyRow, rhs: AppPolicyRow) -> Bool {
        lhs.bundleID == rhs.bundleID && lhs.name == rhs.name && lhs.policy == rhs.policy
    }
}

/// One word in the vocabulary tab, promoted or still counting.
struct VocabularyRow: Identifiable, Equatable {
    var id: String { word }
    let word: String
    let count: Int
    /// Already treated as a real word rather than still accumulating.
    let promoted: Bool
    /// Added by hand, so it never had to reach the threshold.
    let manual: Bool
}

/// Main-thread mirror of the settings blob, plus the two things that live
/// outside it: the login-item registration and the resolved app names.
///
/// Every write goes straight to `SettingsStore`, which persists it and calls
/// back through `AppDelegate` into `accept(_:)`. The UI therefore never holds a
/// value the pipeline has not already been given — there is no Apply button and
/// nothing to keep in step.
final class SettingsModel: ObservableObject {
    @Published private(set) var settings: AppSettings
    @Published private(set) var policyRows: [AppPolicyRow] = []
    @Published private(set) var skipRows: [AppPolicyRow] = []
    @Published private(set) var loginStatus: LoginItemStatus = .disabled
    @Published private(set) var vocabRows: [VocabularyRow] = []
    /// Which language's words the vocabulary tab is showing.
    @Published var vocabLanguage: Language = .english {
        didSet { if vocabLanguage != oldValue { rebuildVocabulary() } }
    }

    private let store: SettingsStore
    private let lexicon: UserLexicon

    init(store: SettingsStore, lexicon: UserLexicon) {
        self.store = store
        self.lexicon = lexicon
        settings = store.settings
        // The rows are deliberately not built here. This model is created at
        // launch for a window that may never be opened, and building them costs
        // two LaunchServices lookups per policy entry. `refresh()` builds them
        // on first show.
    }

    // MARK: - Reading

    /// Called on every show, and the only place the rows are built from
    /// scratch. Everything the window displays is re-read here, so `accept` is
    /// free to do nothing while the window is hidden.
    func refresh() {
        settings = store.settings
        rebuildRows()
        rebuildVocabulary()
        refreshLoginStatus()
    }

    /// Rebuilt on show and after every edit, never continuously: words are
    /// counted on the typing queue and a list that renumbered itself while
    /// being read would be worse than one that is a few seconds old.
    private func rebuildVocabulary() {
        let language = vocabLanguage
        let manual = Set(lexicon.manualWords(language))
        let known = lexicon.learned(language).map {
            VocabularyRow(
                word: $0.word, count: $0.count, promoted: true,
                manual: manual.contains($0.word))
        }
        // Manual entries never accumulate a count, so `learned` cannot see
        // them; without this they would vanish the moment they were added.
        let listed = Set(known.map(\.word))
        let byHand = manual.subtracting(listed).sorted().map {
            VocabularyRow(word: $0, count: 0, promoted: true, manual: true)
        }
        let waiting = lexicon.pending(language).map {
            VocabularyRow(word: $0.word, count: $0.count, promoted: false, manual: false)
        }
        vocabRows = known + byHand + waiting
    }

    // MARK: - Vocabulary

    func addWord(_ word: String) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lexicon.add(trimmed, language: vocabLanguage)
        _ = lexicon.save()
        rebuildVocabulary()
    }

    func removeWord(_ word: String) {
        lexicon.remove(word, language: vocabLanguage)
        _ = lexicon.save()
        rebuildVocabulary()
    }

    func eraseVocabulary() {
        lexicon.clear()
        rebuildVocabulary()
    }

    func refreshLoginStatus() {
        let status = LoginItem.status
        if status != loginStatus { loginStatus = status }
    }

    /// The store's change notification. Also the tail of every write below, so
    /// the published value is always the persisted one.
    ///
    /// The tables are rebuilt only when the maps they are built from actually
    /// changed. Aggressiveness, pause and debug logging move far more often —
    /// ⌘⌥P is a global chord meant for emergencies — and each rebuild is two
    /// LaunchServices round trips per row on the main thread.
    func accept(_ updated: AppSettings) {
        guard updated != settings else { return }
        let tablesChanged =
            updated.appPolicies != settings.appPolicies
            || updated.axVerifySkip != settings.axVerifySkip
        settings = updated
        if tablesChanged { rebuildRows() }
    }

    private func rebuildRows() {
        policyRows = settings.appPolicies
            .map { row(bundleID: $0.key, policy: $0.value) }
            .sorted(by: Self.byName)
        skipRows = settings.axVerifySkip
            .map { row(bundleID: $0, policy: settings.policy(for: $0)) }
            .sorted(by: Self.byName)
    }

    private func row(bundleID: String, policy: AppPolicy) -> AppPolicyRow {
        AppPolicyRow(
            bundleID: bundleID,
            name: AppDirectory.displayName(for: bundleID),
            icon: AppDirectory.icon(for: bundleID),
            policy: policy)
    }

    /// Name first, identifier as the tie-break — two uninstalled apps can
    /// resolve to the same name, and a list whose order flickers is unusable.
    private static func byName(_ lhs: AppPolicyRow, _ rhs: AppPolicyRow) -> Bool {
        let comparison = lhs.name.localizedStandardCompare(rhs.name)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return lhs.bundleID < rhs.bundleID
    }

    // MARK: - Writing

    func setAggressiveness(_ level: Aggressiveness) {
        store.setAggressiveness(level)
        accept(store.settings)
    }

    func setConfidentScore(_ score: Double?) {
        store.setConfidentScore(score)
        accept(store.settings)
    }

    func setPaused(_ paused: Bool) {
        store.setPaused(paused)
        accept(store.settings)
    }

    func setDebugLogging(_ enabled: Bool) {
        store.setDebugLogging(enabled)
        accept(store.settings)
    }

    func setDefaultPolicy(_ policy: AppPolicy) {
        store.setDefaultPolicy(policy)
        accept(store.settings)
    }

    func setPolicy(_ policy: AppPolicy, for bundleID: String) {
        store.setPolicy(policy, for: bundleID)
        accept(store.settings)
    }

    /// Removing a row is not "set it to the default": it deletes the override,
    /// so the app follows `defaultPolicy` from then on, including if that
    /// default later changes.
    func removePolicy(for bundleID: String) {
        store.removePolicy(for: bundleID)
        accept(store.settings)
    }

    func addPolicy(for bundleID: String) {
        guard settings.appPolicies[bundleID] == nil else { return }
        setPolicy(settings.defaultPolicy, for: bundleID)
    }

    func addAXVerifySkip(_ bundleID: String) {
        store.setAXVerifySkip(settings.axVerifySkip.union([bundleID]))
        accept(store.settings)
    }

    func removeAXVerifySkip(_ bundleID: String) {
        store.setAXVerifySkip(settings.axVerifySkip.subtracting([bundleID]))
        accept(store.settings)
    }

    func setLoginItemEnabled(_ enabled: Bool) {
        loginStatus = LoginItem.setEnabled(enabled)
    }

    func openLoginItemSettings() {
        LoginItem.openSettings()
    }
}

/// Lazily created settings window.
///
/// Same shape as `DebugWindowController`: the app has no SwiftUI `App`
/// lifecycle, so this is a plain `NSWindow` hosting a SwiftUI view.
final class SettingsWindowController {
    let model: SettingsModel
    private var window: NSWindow?

    init(settings: SettingsStore, lexicon: UserLexicon) {
        model = SettingsModel(store: settings, lexicon: lexicon)
    }

    var isVisible: Bool { window?.isVisible == true }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        model.refresh()
        // `makeKeyAndOrderFront` and not `NSApp.activate`: onboarding is the one
        // place this app is allowed to take the screen away from whatever the
        // user is typing in. Opening the menu already brings Dodoma forward for
        // the duration of the click, which is enough for the window to come up
        // usable.
        window.makeKeyAndOrderFront(nil)
    }

    /// Driven by the app delegate's existing two-second permission poll rather
    /// than by a timer of its own. Approval of a login item happens in System
    /// Settings, so the status has to be re-read from outside.
    func poll() {
        guard isVisible else { return }
        model.refreshLoginStatus()
    }

    /// Same guard as `poll()`, and for a stronger reason: this one is called
    /// from `SettingsStore.onChange`, so without it every pause toggle for the
    /// rest of the session would rebuild the policy tables for a window nobody
    /// has opened. `show()` calls `refresh()`, so a hidden window cannot go
    /// stale by being skipped here.
    func settingsChanged(_ settings: AppSettings) {
        guard isVisible else { return }
        model.accept(settings)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.title = "Harf Settings"
        window.isReleasedWhenClosed = false
        // The starfield runs edge to edge, so the title bar has to stop being
        // an opaque strip across the top of it.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(red: 0.043, green: 0.055, blue: 0.075, alpha: 1)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        window.center()
        window.setFrameAutosaveName("HarfSettingsWindow")
        return window
    }
}

// MARK: - Views

private struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        ZStack {
            DodomaTheme.canvas
            // White reads as starlight; the teal is saved for the accents so
            // the two do not compete.
            GravityStarsBackground(
                starCount: 90, starSize: 2.2, starOpacity: 0.85,
                starColor: Color(red: 0.87, green: 0.95, blue: 0.98))

            VStack(spacing: 0) {
                header
                TabView {
                    GeneralTab(model: model)
                        .tabItem { Text("General") }
                    ApplicationsTab(model: model)
                        .tabItem { Text("Applications") }
                    VocabularyTab(model: model)
                        .tabItem { Text("Vocabulary") }
                    AdvancedTab(model: model)
                        .tabItem { Text("Advanced") }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .frame(width: 560, height: 520)
        .preferredColorScheme(.dark)
    }

    /// The window has no title bar text of its own now, so the wordmark and the
    /// live status line carry the identity instead.
    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(DodomaTheme.accent)
                .frame(width: 7, height: 7)
                .shadow(color: DodomaTheme.accent.opacity(0.8), radius: 5)
            Text("HARF")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .kerning(2.4)
                .foregroundStyle(DodomaTheme.accent)
            Spacer()
            Text("ع  ⇄  EN")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.35))
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 16)
    }
}

private struct GeneralTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Picker("Aggressiveness", selection: aggressiveness) {
                    ForEach(Aggressiveness.allCases, id: \.self) { level in
                        Text(SettingsCopy.title(level)).tag(level)
                    }
                }
                .pickerStyle(.radioGroup)
                Text(SettingsCopy.explanation(model.settings.aggressiveness))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Section {
                Toggle("Fix short text when the score is high", isOn: confidenceEnabled)
                if let score = model.settings.confidentScore {
                    HStack(spacing: 12) {
                        Slider(value: confidenceScore, in: 0.60...0.99, step: 0.01)
                        Text(SettingsCopy.percent(score))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(DodomaTheme.accent)
                            .frame(width: 46, alignment: .trailing)
                            .monospacedDigit()
                    }
                }
                Text(SettingsCopy.confidenceExplanation(model.settings.confidentScore))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Section {
                Toggle("Pause Harf", isOn: paused)
                Text("Nothing is buffered, evaluated or rewritten while this is on. "
                    + "The same switch as ⌘⌥P and the menu item.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Section {
                Toggle("Start Harf at login", isOn: loginItem)
                    .disabled(model.loginStatus == .unavailable)
                if !model.loginStatus.explanation.isEmpty {
                    Text(model.loginStatus.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.loginStatus == .requiresApproval {
                    Button("Open Login Items Settings…") { model.openLoginItemSettings() }
                }
            }

            Divider()

            Section {
                Toggle("Debug logging", isOn: debugLogging)
                Text("Logs the text of detected regions to the system log. "
                    + "Leave this off unless you are diagnosing a wrong fix.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    /// Turning the rule off restores the length rules; turning it on returns
    /// to a deliberately cautious score rather than wherever the slider last
    /// sat, so an accidental toggle cannot leave it wide open.
    private var confidenceEnabled: Binding<Bool> {
        Binding(
            get: { model.settings.confidentScore != nil },
            set: { model.setConfidentScore($0 ? (model.settings.confidentScore ?? 0.80) : nil) })
    }

    private var confidenceScore: Binding<Double> {
        Binding(
            get: { model.settings.confidentScore ?? 0.80 },
            set: { model.setConfidentScore($0) })
    }

    private var aggressiveness: Binding<Aggressiveness> {
        Binding(get: { model.settings.aggressiveness }, set: { model.setAggressiveness($0) })
    }

    private var paused: Binding<Bool> {
        Binding(get: { model.settings.paused }, set: { model.setPaused($0) })
    }

    private var debugLogging: Binding<Bool> {
        Binding(get: { model.settings.debugLogging }, set: { model.setDebugLogging($0) })
    }

    private var loginItem: Binding<Bool> {
        Binding(get: { model.loginStatus.isOn }, set: { model.setLoginItemEnabled($0) })
    }
}

private struct ApplicationsTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("All other apps")
                    .frame(maxWidth: .infinity, alignment: .leading)
                PolicyPicker(
                    policy: model.settings.defaultPolicy,
                    onChange: { model.setDefaultPolicy($0) })
            }
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))

            List {
                ForEach(model.policyRows) { row in
                    HStack(spacing: 8) {
                        AppIcon(image: row.icon)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.name)
                            Text(row.bundleID)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        PolicyPicker(
                            policy: row.policy,
                            onChange: { model.setPolicy($0, for: row.bundleID) })
                        Button {
                            model.removePolicy(for: row.bundleID)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this override; the app follows the default above.")
                    }
                }
            }
            .frame(maxHeight: .infinity)

            HStack {
                Button("+ Add app…") { addApp() }
                Spacer()
                Text("Removing a row does not switch Harf off for that app — it reverts it "
                    + "to the default above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func addApp() {
        guard let bundleID = AppChooser.chooseBundleID(
            prompt: "Choose an application to give its own mode.")
        else { return }
        model.addPolicy(for: bundleID)
    }
}

private struct VocabularyTab: View {
    @ObservedObject var model: SettingsModel
    @State private var newWord: String = ""
    @State private var confirmingErase = false

    private var known: Int { model.vocabRows.filter(\.promoted).count }
    private var waiting: Int { model.vocabRows.count - known }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $model.vocabLanguage) {
                Text("English").tag(Language.english)
                Text("العربية").tag(Language.arabic)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text("The bundled word lists come from subtitles, so the words you use at work "
                + "score as nonsense. Harf counts the words it sees you type and keeps "
                + "them at \(UserLexicon.promotionThreshold) sightings, which stops your own "
                + "vocabulary from dragging a reading down. It counts typos too — it can "
                + "only tell wrong layout from right, not right spelling from wrong — so "
                + "this is the list to prune.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !model.settings.learnVocabulary {
                Label("Learning is off. Nothing new is counted; words added by hand still "
                    + "count.", systemImage: "pause.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("\(known) known · \(waiting) on the way")
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                ForEach(model.vocabRows) { row in
                    HStack(spacing: 8) {
                        // Monospaced suits Latin tokens, which are often
                        // command names, and ruins Arabic: fixed advance widths
                        // stretch the joins between letters until a word reads
                        // as separated characters.
                        Text(row.word)
                            .font(.system(
                                size: 13,
                                design: model.vocabLanguage == .arabic ? .default : .monospaced))
                        Spacer()
                        Text(label(for: row))
                            .font(.caption2)
                            .foregroundStyle(row.promoted ? .primary : .secondary)
                        Button {
                            model.removeWord(row.word)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Forget this word.")
                    }
                }
            }
            .frame(maxHeight: .infinity)

            HStack(spacing: 8) {
                TextField("Add a word Harf should always accept", text: $newWord)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commit() }
                Button("Add") { commit() }
                    .disabled(newWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Erase all…") { confirmingErase = true }
            }
            .confirmationDialog(
                "Erase every learned word?",
                isPresented: $confirmingErase,
                titleVisibility: .visible
            ) {
                Button("Erase", role: .destructive) { model.eraseVocabulary() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Both languages, including words added by hand. Harf starts counting "
                    + "again from nothing.")
            }
        }
    }

    private func commit() {
        model.addWord(newWord)
        newWord = ""
    }

    /// Manual entries have no count to show, and saying "0/10" next to a word
    /// that is already accepted would read as the opposite of the truth.
    private func label(for row: VocabularyRow) -> String {
        if row.manual { return "added by hand" }
        if row.promoted { return "known · seen \(row.count)×" }
        return "\(row.count)/\(UserLexicon.promotionThreshold)"
    }
}

private struct AdvancedTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Skip accessibility verification")
                .font(.headline)
            Text("Before deleting anything, Harf reads the text in front of the caret and "
                + "checks that it is exactly what it recorded you typing. Apps listed here "
                + "skip that read: the rewrite goes ahead unverified, so a stale buffer "
                + "deletes whatever happens to be in front of the caret instead. The list "
                + "exists for apps where touching the accessibility tree is expensive — "
                + "Chromium force-enables its whole tree the moment anything reads it. Empty "
                + "is the right answer unless you have that specific problem.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List {
                ForEach(model.skipRows) { row in
                    HStack(spacing: 8) {
                        AppIcon(image: row.icon)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.name)
                            Text(row.bundleID)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            model.removeAXVerifySkip(row.bundleID)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .frame(minHeight: 120)

            Button("+ Add app…") { addApp() }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("Undo window").foregroundStyle(.secondary)
                    Text(SettingsCopy.undoWindow)
                }
                GridRow {
                    Text("Shortcuts").foregroundStyle(.secondary)
                    Text(
                        "\(SettingsCopy.undoChord) / \(SettingsCopy.pauseChord) "
                            + "/ \(SettingsCopy.flipChord)")
                }
                GridRow {
                    Text("").foregroundStyle(.secondary)
                    Text("undo / pause / flip — rebinding not yet supported")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(.body, design: .monospaced))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func addApp() {
        guard let bundleID = AppChooser.chooseBundleID(
            prompt: "Choose an application to exempt from caret verification.")
        else { return }
        model.addAXVerifySkip(bundleID)
    }
}

private struct PolicyPicker: View {
    let policy: AppPolicy
    let onChange: (AppPolicy) -> Void

    var body: some View {
        Picker(
            "",
            selection: Binding(get: { policy }, set: { onChange($0) })
        ) {
            ForEach(AppPolicy.allCases, id: \.self) { option in
                Text(SettingsCopy.title(option)).tag(option)
            }
        }
        .labelsHidden()
        .frame(width: 140)
    }
}

private struct AppIcon: View {
    let image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable()
            } else {
                Image(systemName: "questionmark.app.dashed")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 18, height: 18)
    }
}

/// The open panel behind both "+ Add app…" buttons.
private enum AppChooser {
    /// nil when the user cancels, or when the thing they picked is not an app
    /// bundle — a bundle with no identifier cannot be keyed on, and silently
    /// adding nothing would look like the button was broken.
    static func chooseBundleID(prompt: String) -> String? {
        let panel = NSOpenPanel()
        panel.message = prompt
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard let bundleID = AppDirectory.bundleID(atApplicationURL: url) else {
            let alert = NSAlert()
            alert.messageText = "That application has no bundle identifier."
            alert.informativeText =
                "Harf keys its settings on the bundle identifier, so \(url.lastPathComponent) "
                + "cannot be added."
            alert.alertStyle = .warning
            alert.runModal()
            return nil
        }
        return bundleID
    }
}

/// Every user-facing string in the settings window, in one place.
enum SettingsCopy {
    static func percent(_ score: Double) -> String { "\(Int((score * 100).rounded()))%" }

    /// What the confidence rule is for, in the terms the user meets it in: a
    /// single word that was plainly wrong and was not corrected.
    static func confidenceExplanation(_ score: Double?) -> String {
        guard let score else {
            return "Off. A single word is never rewritten silently, however certain the "
                + "reading is; it is offered as a suggestion instead. Turn this on if short "
                + "words are the ones you keep fixing by hand."
        }
        return "A run scoring at least \(percent(score)) in the other layout is "
            + "rewritten even when it is one short word. Below that, the usual length rules "
            + "apply. Text under three letters is never rewritten, and a URL, a path or an "
            + "identifier is left alone at any setting."
    }

    static func title(_ level: Aggressiveness) -> String {
        switch level {
        case .conservative: return "Conservative"
        case .balanced: return "Balanced"
        case .eager: return "Eager"
        }
    }

    static func explanation(_ level: Aggressiveness) -> String {
        switch level {
        case .conservative:
            return "Rewrites only when the other layout is an overwhelming improvement. "
                + "Misses some real mistakes; almost never touches text it should not."
        case .balanced:
            return "The default. Rewrites clear cases, offers the borderline ones as a "
                + "suggestion card next to the caret."
        case .eager:
            return "Rewrites on a smaller margin and offers more. Catches more mistakes and "
                + "produces more wrong fixes; ⌘⌥Z is the way back from those."
        }
    }

    static func title(_ policy: AppPolicy) -> String {
        switch policy {
        case .normal: return "Normal"
        case .suggestOnly: return "Suggest only"
        case .off: return "Off"
        }
    }

    static var undoWindow: String {
        "\(Int(FixHistory.undoWindow.rounded())) s"
    }

    /// Spelled out rather than derived: a hot key is a key code and a rendered
    /// chord is characters, and nothing translates one into the other without
    /// asking the active layout. `SettingsCopyTests` pins these against
    /// `Hotkeys` so the two cannot drift.
    ///
    /// The modifiers are in macOS's canonical order — ⌃⌥⇧⌘ — which is how
    /// `NSMenuItem` renders the same chord two items further up the menu.
    /// Prose elsewhere writes it ⌘⌥Z; these two are what the user is asked to
    /// compare against the menu, so they match the menu.
    static let undoChord = "⌥⌘Z"
    static let pauseChord = "⌥⌘P"
    static let flipChord = "⌃⌘F"
}
