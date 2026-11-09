import SwiftUI
import WakeKit

/// Full-screen voice surface shown from "hi mac" until the turn ends.
///
/// The rings and bars are driven by `state.audioLevel`, so what moves on screen
/// is the actual microphone loudness rather than a canned animation.
struct ImmersiveOverlay: View {
    @ObservedObject var state: AppState
    var onDismiss: () -> Void

    @FocusState private var typingFocused: Bool

    var body: some View {
        ZStack {
            // The hosting view outlives an ordered-out panel, and
            // TimelineView(.animation) would keep a 30 fps display link running
            // behind it. Collapsing to an empty layer while hidden is what stops
            // the redraw loop, not hiding the window.
            if state.showingOverlay {
                presented
            } else {
                Color.clear
            }
        }
        .ignoresSafeArea()
        .onAppear { typingFocused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Wake Mac listening, \(phase.label)")
    }

    /// Everything that animates. Built only while the surface is on screen.
    private var presented: some View {
        ZStack {
            backdrop
            VStack(spacing: 0) {
                header
                Spacer(minLength: 12)
                VStack(spacing: 22) {
                    voiceStage
                    transcriptBlock
                    actionBlock
                }
                Spacer(minLength: 12)
                composer
                footer
            }
            .padding(.horizontal, 64)
            .padding(.vertical, 36)
            .frame(maxWidth: 1180)
        }
    }

    private var phase: PhaseStyle { PhaseStyle(state.phase) }

    // MARK: - Layers

    /// Dimmed desktop plus a soft accent glow that tracks the current phase.
    private var backdrop: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Rectangle().fill(Color.black.opacity(0.42))
            RadialGradient(
                colors: [phase.accent.opacity(0.32 + 0.22 * state.audioLevel), .clear],
                center: .center,
                startRadius: 10,
                endRadius: 760)
            .blendMode(.plusLighter)
            .animation(.easeOut(duration: 0.35), value: state.audioLevel)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: phase.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(phase.accent)
            Text(phase.label)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
            if state.phase == .thinking || state.phase == .executing {
                ProgressView().controlSize(.small).padding(.leading, 2)
            }
            Spacer()
            Button(action: onDismiss) {
                HStack(spacing: 6) {
                    Text("esc").font(.system(size: 11, weight: .semibold, design: .monospaced))
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(.white.opacity(0.1)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Dismiss (Esc)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .background(Capsule().fill(.black.opacity(0.25)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
    }

    /// Pulse rings + live waveform — the centrepiece.
    private var voiceStage: some View {
        ZStack {
            PulseRings(level: state.audioLevel, accent: phase.accent, active: phase.isLive)
            VStack(spacing: 18) {
                Image(systemName: phase.isLive ? "waveform" : phase.symbol)
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(phase.accent)
                    .shadow(color: phase.accent.opacity(0.7), radius: 18)
                Waveform(level: state.audioLevel, accent: phase.accent, active: phase.isLive)
                    .frame(width: 240, height: 42)
            }
        }
        .frame(height: 300)
    }

    private var transcriptBlock: some View {
        VStack(spacing: 10) {
            if !state.transcript.isEmpty || !state.request.isEmpty {
                Text(state.transcript.isEmpty ? state.request : state.transcript)
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else {
                Text("Say what you want done")
                    .font(.system(size: 28, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            if !state.answer.isEmpty {
                Text(state.answer)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
            }
        }
        .animation(.easeOut(duration: 0.25), value: state.transcript)
        .frame(maxWidth: 820)
        .padding(.bottom, 8)
    }

    /// What the planner decided, and how each step actually went.
    @ViewBuilder private var actionBlock: some View {
        if !state.planSummary.isEmpty || !state.results.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if !state.planSummary.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(phase.accent)
                        Text(state.planSummary)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                    }
                }
                ForEach(state.results) { result in
                    HStack(spacing: 10) {
                        Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(result.success ? .green : .red)
                            .font(.system(size: 14))
                        Text(StepNaming.label(result.step))
                            .font(.system(size: 13, weight: .medium))
                        Spacer(minLength: 12)
                        Text(result.verification)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .transition(.opacity)
                }
            }
            .padding(18)
            .frame(maxWidth: 720, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.black.opacity(0.3)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.09)))
            .animation(.easeOut(duration: 0.25), value: state.results.count)
        }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            Image(systemName: "keyboard")
                .foregroundStyle(.secondary)
                .font(.system(size: 13))
            TextField("…or type it instead", text: $state.typedInput)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($typingFocused)
                .onSubmit { state.submitTyped() }
            if state.phase != .standby {
                Button("Stop") { state.stopOrCancel() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: 560)
        .background(Capsule().fill(.black.opacity(0.35)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if state.micPermissionDenied {
                Label("Microphone denied — typing still works", systemImage: "mic.slash")
                    .foregroundStyle(.orange)
            } else if !state.engineLabel.isEmpty {
                Label(state.engineLabel, systemImage: "cpu")
            }
            if !state.statusDetail.isEmpty {
                Text(state.statusDetail).lineLimit(1).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.top, 14)
    }
}

// MARK: - Pulse rings

/// Concentric rings that breathe continuously and jump with microphone level.
private struct PulseRings: View {
    let level: Double
    let accent: Color
    let active: Bool

    /// Built once per colour instead of per frame; the rings rotate the view.
    static func sweep(_ accent: Color) -> AngularGradient {
        AngularGradient(
            colors: [accent.opacity(0.0), accent.opacity(0.55),
                     accent.opacity(0.1), accent.opacity(0.0)],
            center: .center)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<4, id: \.self) { index in
                    let phase = Double(index) * 0.6
                    // Slow breath so the surface is alive even in silence…
                    let breath = 1 + 0.035 * sin(t * 1.1 + phase)
                    // …and a level-driven push so speaking visibly expands it.
                    let push = active ? 1 + level * (0.26 - Double(index) * 0.045) : 1
                    let base = 150.0 + Double(index) * 62.0
                    Circle()
                        .strokeBorder(Self.sweep(accent), lineWidth: index == 0 ? 2.4 : 1.2)
                        .frame(width: base * breath * push, height: base * breath * push)
                        .rotationEffect(.degrees(t * 26 * (index.isMultiple(of: 2) ? 1 : -1)))
                        .opacity(active ? 1 : 0.4)
                }
                // Soft core that brightens with loudness.
                Circle()
                    .fill(RadialGradient(colors: [accent.opacity(0.30 + 0.3 * level), .clear],
                                         center: .center, startRadius: 0, endRadius: 120))
                    .frame(width: 240, height: 240)
            }
        }
    }
}

// MARK: - Waveform

/// Symmetric bar meter. Each bar gets its own offset so the shape reads as
/// speech rather than a single bouncing block.
private struct Waveform: View {
    let level: Double
    let accent: Color
    let active: Bool

    private let barCount = 21

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 4) {
                ForEach(0..<barCount, id: \.self) { index in
                    let distance = abs(Double(index) - Double(barCount - 1) / 2)
                    let falloff = 1 - (distance / Double(barCount)) * 1.4
                    let wobble = 0.5 + 0.5 * sin(t * 6 + Double(index) * 0.7)
                    let amplitude = active
                        ? max(0.08, level * falloff * (0.55 + 0.75 * wobble))
                        : 0.06 + 0.03 * wobble
                    Capsule()
                        .fill(accent.opacity(active ? 0.95 : 0.4))
                        .frame(width: 4, height: max(4, amplitude * 42))
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - Phase presentation

/// Colour, glyph and wording for each state of the session machine.
struct PhaseStyle {
    let phase: AppState.Phase

    init(_ phase: AppState.Phase) { self.phase = phase }

    var accent: Color {
        switch phase {
        case .standby: return Color(red: 0.55, green: 0.60, blue: 0.70)
        case .listening, .transcribing: return Color(red: 0.36, green: 0.68, blue: 1.0)
        case .thinking: return Color(red: 1.0, green: 0.70, blue: 0.26)
        case .executing: return Color(red: 0.70, green: 0.46, blue: 1.0)
        case .speaking: return Color(red: 0.26, green: 0.84, blue: 0.76)
        case .cancelled: return Color(red: 0.95, green: 0.82, blue: 0.35)
        case .failed: return Color(red: 1.0, green: 0.42, blue: 0.42)
        }
    }

    var symbol: String {
        switch phase {
        case .standby: return "mic"
        case .listening: return "waveform"
        case .transcribing: return "text.viewfinder"
        case .thinking: return "brain"
        case .executing: return "bolt.horizontal"
        case .speaking: return "speaker.wave.2"
        case .cancelled: return "hand.raised"
        case .failed: return "exclamationmark.triangle"
        }
    }

    var label: String {
        switch phase {
        case .standby: return "Ready — say “hi mac”"
        case .listening: return "Listening"
        case .transcribing: return "Transcribing"
        case .thinking: return "Thinking"
        case .executing: return "Doing it"
        case .speaking: return "Speaking"
        case .cancelled: return "Cancelled"
        case .failed: return "Failed"
        }
    }

    /// Whether the microphone is the thing driving the animation right now.
    var isLive: Bool {
        phase == .listening || phase == .transcribing
    }
}

/// Shared step wording, used by both overlays.
enum StepNaming {
    static func label(_ step: ActionStep) -> String {
        switch step.kind {
        case .launchApp: return "Open \(step.argument)"
        case .openURL: return "Open \(step.argument)"
        case .openPath: return "Reveal \(step.argument)"
        case .runShortcut: return "Shortcut “\(step.argument)”"
        case .applesEvent: return "Apple event \(step.argument)"
        case .typeText: return "Type text"
        case .keystroke: return "Press \(step.argument)"
        case .waitSeconds: return "Wait \(step.argument)s"
        case .setVolume: return "Volume \(step.argument)"
        }
    }
}
