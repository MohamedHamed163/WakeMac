import SwiftUI
import WakeKit

/// Voice overlay shown below the top safe area on any display.
struct OverlayView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                phaseIndicator
                Text(phaseLabel).font(.headline)
                Spacer()
                Button {
                    state.stopOrCancel()
                } label: {
                    Image(systemName: "stop.circle")
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Stop (Esc)")
            }
            if !state.transcript.isEmpty {
                Text("“\(state.transcript)”").foregroundStyle(.secondary).lineLimit(2)
            }
            if !state.planSummary.isEmpty {
                Label(state.planSummary, systemImage: "list.bullet.rectangle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !state.results.isEmpty {
                ForEach(state.results) { result in
                    HStack {
                        Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(result.success ? .green : .red)
                        Text(stepLabel(result))
                            .font(.caption)
                        Spacer()
                        Text(result.verification).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            if !state.answer.isEmpty {
                Text(state.answer).font(.callout)
            }
            if !state.statusDetail.isEmpty {
                Text(state.statusDetail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack {
                TextField("Or type a request…", text: $state.typedInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { state.submitTyped() }
                Button("Send") { state.submitTyped() }
            }
            if state.micPermissionDenied {
                Label("Microphone denied — typed input remains available.",
                      systemImage: "mic.slash").font(.caption).foregroundStyle(.orange)
            }
            if !state.speechStatus.isEmpty && state.speechStatus.contains("NOT") {
                Label(state.speechStatus, systemImage: "speaker.slash")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(16)
        .frame(width: 460)
        .background(RoundedRectangle(cornerRadius: 16).fill(.regularMaterial)
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary)))
        .shadow(radius: 14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Wake Mac assistant overlay, phase \(phaseLabel)")
    }

    var phaseColor: Color {
        switch state.phase {
        case .standby: return .gray
        case .listening, .transcribing: return .blue
        case .thinking: return .orange
        case .executing: return .purple
        case .speaking: return .teal
        case .cancelled: return .yellow
        case .failed: return .red
        }
    }

    var phaseLabel: String {
        switch state.phase {
        case .standby: return "Standby — say “\(state.settings.wakePhrase)” or ⌥Space"
        case .listening: return "Listening"
        case .transcribing: return "Transcribing"
        case .thinking: return "Thinking"
        case .executing: return "Executing"
        case .speaking: return "Speaking"
        case .cancelled: return "Cancelled"
        case .failed: return "Failed"
        }
    }

    var phaseIndicator: some View {
        return Circle().fill(phaseColor).frame(width: 10, height: 10)
    }

    func stepLabel(_ result: ActionResult) -> String {
        switch result.step.kind {
        case .launchApp: return "Launch \(result.step.argument)"
        case .openURL: return "Open URL"
        case .openPath: return "Open path"
        case .runShortcut: return "Shortcut \(result.step.argument)"
        case .applesEvent: return "Apple event \(result.step.argument)"
        case .typeText: return "Type text"
        case .keystroke: return "Key \(result.step.argument)"
        case .waitSeconds: return "Wait"
        case .setVolume: return "Volume \(result.step.argument)"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        Form {
            Section("Local reasoning (Ollama)") {
                TextField("Endpoint", text: Binding(
                    get: { state.settings.ollamaBaseURL },
                    set: { state.settings.ollamaBaseURL = $0; persist() }))
                Button("Check") { Task { _ = await state.checkOllama() } }
            }
            Section("Voice") {
                TextField("Wake phrase", text: Binding(
                    get: { state.settings.wakePhrase },
                    set: { state.settings.wakePhrase = $0.lowercased(); persist() }))
                Toggle("Require on-device recognition (never cloud)", isOn: Binding(
                    get: { state.settings.requireOnDeviceRecognition },
                    set: { state.settings.requireOnDeviceRecognition = $0; persist() }))
                Toggle("Speak responses", isOn: Binding(
                    get: { state.settings.speakResponses },
                    set: { state.settings.speakResponses = $0; state.speechOutput.enabled = $0; persist() }))
                Text(state.speechStatus).font(.caption).foregroundStyle(.secondary)
            }
            Section("Session") {
                Stepper("Command timeout: \(Int(state.settings.commandTimeoutSeconds))s",
                        value: Binding(get: { state.settings.commandTimeoutSeconds },
                                       set: { state.settings.commandTimeoutSeconds = $0; persist() }),
                        in: 5...60)
                Stepper("Self-trigger cooldown: \(state.settings.preventSelfTriggerMillis)ms",
                        value: Binding(get: { state.settings.preventSelfTriggerMillis },
                                       set: { state.settings.preventSelfTriggerMillis = $0; persist() }),
                        in: 500...5000)
            }
            Section("History") {
                ForEach(state.history.recent(limit: 10)) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.request).lineLimit(1)
                        HStack {
                            Text(entry.state).font(.caption2)
                            Text(entry.timestamp.formatted(date: .omitted, time: .shortened))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 480)
    }

    func persist() {
        state.settings.save(to: state.paths.settingsPath)
    }
}

struct ModesEditorView: View {
    @ObservedObject var state: AppState
    @State private var modes: [SavedMode] = []
    @State private var selected: SavedMode?
    @State private var stepsText = ""
    @State private var statusText = ""

    var body: some View {
        HSplitView {
            List(modes, selection: $selected) { mode in
                VStack(alignment: .leading) {
                    HStack {
                        Text(mode.name)
                        if !mode.enabled {
                            Text("disabled").font(.caption2).foregroundStyle(.orange)
                        }
                    }
                    Text(mode.aliases.joined(separator: ", ")).font(.caption2).foregroundStyle(.secondary)
                }
                .tag(mode)
            }
            .frame(minWidth: 220)
            VStack(alignment: .leading, spacing: 8) {
                if let mode = selected {
                    Text(mode.descriptionText).font(.callout)
                    TextField("Steps (one per line: kind:argument[:extra])", text: $stepsText, axis: .vertical)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 140)
                    // Two rows: six buttons in one row truncated every label
                    // at the window's default width.
                    HStack {
                        Button("Save") { save(mode) }
                        Button("Dry Run") { dryRun(mode) }
                        Button("Duplicate") { duplicate(mode) }
                        Spacer()
                        Button("Run “\(mode.name)”") { state.runMode(named: mode.name) }
                            .buttonStyle(.borderedProminent)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(mode.enabled ? "Disable" : "Enable") { toggleEnabled(mode) }
                        Button("Delete", role: .destructive) {
                            state.modeStore.delete(mode)
                            reload()
                            selected = nil
                        }
                        Spacer()
                    }
                    if !mode.preconditions.isNilOrEmpty {
                        Text("Preconditions: \(mode.preconditions!)").font(.caption2).foregroundStyle(.orange)
                    }
                } else {
                    ContentUnavailableView("Select a mode", systemImage: "square.stack.3d.up")
                }
                Spacer()
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }
            .padding()
            .frame(minWidth: 380)
        }
        .onAppear(perform: reload)
        .onChange(of: selected) { mode in
            stepsText = mode?.steps.map { step in
                [step.kind.rawValue, step.argument, step.extra ?? ""].filter { !$0.isEmpty }.joined(separator: ":")
            }.joined(separator: "\n") ?? ""
        }
    }

    func reload() {
        modes = state.modeStore.modes()
    }

    func parseSteps(_ text: String) -> [ActionStep] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: ":", maxSplits: 2).map { String($0).trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 2, let kind = ActionKind(rawValue: parts[0]) else { return nil }
            return ActionStep(kind: kind, argument: parts[1], extra: parts.count > 2 ? parts[2] : nil)
        }
    }

    func save(_ mode: SavedMode) {
        var updated = mode
        updated.steps = parseSteps(stepsText)
        updated.version += 1
        state.modeStore.save(updated)
        reload()
        selected = updated
        statusText = "saved v\(updated.version) with \(updated.steps.count) steps"
    }

    func dryRun(_ mode: SavedMode) {
        do {
            try PlanValidator.validate(ActionPlan(summary: mode.name, steps: mode.steps), policy: ExecutionPolicy())
            statusText = "validation OK — \(mode.steps.count) steps would run"
        } catch {
            statusText = "validation failed: \(error)"
        }
    }

    func toggleEnabled(_ mode: SavedMode) {
        var updated = mode
        updated.enabled.toggle()
        state.modeStore.save(updated)
        reload()
        selected = updated
    }

    func duplicate(_ mode: SavedMode) {
        selected = state.modeStore.duplicate(mode)
        reload()
    }
}

extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool { self == nil || self!.isEmpty }
}
