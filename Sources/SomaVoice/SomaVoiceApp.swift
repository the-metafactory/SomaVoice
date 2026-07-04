import SwiftUI

@main
struct SomaVoiceApp: App {
    @StateObject private var convo = Conversation()

    var body: some Scene {
        MenuBarExtra("SomaVoice", systemImage: "waveform.circle") {
            ContentView()
                .environmentObject(convo)
                .frame(width: 340)
                .task { convo.requestPermissions() }
        }
        .menuBarExtraStyle(.window)
    }
}

struct ContentView: View {
    @EnvironmentObject var convo: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            brainPicker
            if convo.brainKind == .router { deepPicker }
            Text(convo.state.label)
                .font(.caption)
                .foregroundStyle(statusColor)
            transcriptView
            conversationButton
            talkButton
            hotkeyControls
            wakeControls
            tuning
            footer
        }
        .padding(12)
    }

    private var header: some View {
        HStack {
            Text("SomaVoice").font(.headline)
            Spacer()
            Picker("", selection: personaBinding) {
                ForEach(Persona.all) { Text($0.name).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 90)
            Picker("", selection: Binding(
                get: { convo.sttLanguage }, set: { convo.sttLanguage = $0 })) {
                ForEach(Conversation.SttLanguage.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 78)
            .help("Speech language (on-device: EN, DE-CH)")
            Picker("", selection: Binding(
                get: { convo.sttBackend }, set: { convo.setSttBackend($0) })) {
                ForEach(Conversation.SttBackend.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 96)
            .help("Speech-to-text engine")
        }
    }

    private var personaBinding: Binding<Persona> {
        Binding(get: { convo.persona }, set: { convo.switchPersona($0) })
    }

    private var deepPicker: some View {
        HStack {
            Text("Deep").font(.caption).foregroundStyle(.secondary)
            Picker("Deep", selection: Binding(
                get: { convo.deepSubstrate },
                set: { convo.setDeepSubstrate($0) })) {
                ForEach(Conversation.DeepSubstrate.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var brainPicker: some View {
        HStack {
            Text("Brain").font(.caption).foregroundStyle(.secondary)
            Picker("Brain", selection: Binding(
                get: { convo.brainKind },
                set: { convo.setBrainKind($0) })) {
                ForEach(Conversation.BrainKind.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }

    private var transcriptView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(convo.transcript) { turn in
                        TurnRow(turn: turn).id(turn.id)
                    }
                }
            }
            .frame(height: 220)
            .onChange(of: convo.transcript.count) {
                if let last = convo.transcript.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var conversationButton: some View {
        Button(action: { convo.toggleConversation() }) {
            Label(convo.conversationActive ? "Stop Conversation" : "Start Conversation",
                  systemImage: convo.conversationActive ? "stop.circle.fill" : "waveform.circle.fill")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .tint(convo.conversationActive ? .green : .accentColor)
    }

    private var talkButton: some View {
        Button(action: { convo.toggleTalk() }) {
            Label(talkLabel, systemImage: micIcon)
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .keyboardShortcut(.space, modifiers: [])
        .tint(convo.state == .listening ? .red : .accentColor)
    }

    /// Global ⌃⌥ hotkey is opt-in (needs Accessibility). When not granted, offer a
    /// button that prompts once — instead of nagging on every launch. When granted,
    /// just show the usage hint.
    @ViewBuilder private var hotkeyControls: some View {
        if convo.globalHotkeyTrusted {
            Text("Tap ⌃⌥ (Control+Option) anywhere to start/stop a conversation. Or Talk / Space for one turn.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else {
            HStack {
                Text("Talk or Space for one turn. Want a global ⌃⌥ shortcut?")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button("Enable…") { convo.enableGlobalHotkey() }
                    .font(.caption2)
                    .help("Prompts for Accessibility so Control+Option works from any app.")
            }
        }
    }

    private var wakeControls: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Name").font(.caption).foregroundStyle(.secondary)
                TextField("Ivy", text: Binding(
                    get: { convo.agentName }, set: { convo.agentName = $0 }))
                    .textFieldStyle(.roundedBorder).font(.caption).frame(maxWidth: 140)
                Spacer()
            }
            .help("What your agent calls herself. The wake word is set separately below.")
            HStack {
                Toggle("Wake word", isOn: Binding(
                    get: { convo.wakeEnabled }, set: { convo.setWakeEnabled($0) }))
                    .font(.caption).toggleStyle(.switch).controlSize(.mini)
                Spacer()
                Button("Learn phrase") { convo.learnWakePhrase() }.font(.caption2)
            }
            Text("Say “\(convo.wakePhrase)” to wake. Learn = say your phrase once (2.5s).")
                .font(.caption2).foregroundStyle(.secondary)
            Text("Conversation is half-duplex: Ivy answers, then listens. Say “stop” to end.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var tuning: some View {
        DisclosureGroup("VAD tuning") {
            VStack(alignment: .leading, spacing: 8) {
                // Live mic meter — red marker is the adaptive trigger (noise floor
                // + sensitivity); bar goes green when you're above it.
                LevelMeter(level: convo.micLevel, threshold: convo.micThreshold)
                    .frame(height: 14)

                // Diagnostic readout — report these numbers when tuning.
                Text(String(format: "lvl %.0f · floor %.0f · trig %.0f dB · %@",
                            convo.micLevel, convo.micFloor, convo.micThreshold,
                            convo.micLevel > convo.micThreshold ? "SPEECH" : "—"))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(convo.micLevel > convo.micThreshold ? .green : .secondary)

                Text("stt: \(convo.partialText.isEmpty ? "—" : convo.partialText)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(convo.partialText.hasPrefix("⚠︎") ? .red : .secondary)
                    .lineLimit(2)

                slider("Voice sensitivity", value: Binding(
                    get: { Double(convo.vadMargin) }, set: { convo.setVadMargin(Float($0)) }),
                    range: 3...20, suffix: "\(Int(convo.vadMargin)) dB",
                    help: "dB above the live noise floor that counts as speech. Lower = more sensitive. Auto-calibrates to your mic.")

                slider("End after pause", value: Binding(
                    get: { convo.silenceHang }, set: { convo.setSilenceHang($0) }),
                    range: 0.3...3.0, suffix: String(format: "%.1f s", convo.silenceHang),
                    help: "Silence that ends your turn. Raise if she cuts you off.")

                slider("Max turn length", value: $convo.maxListen,
                    range: 5...30, suffix: "\(Int(convo.maxListen)) s",
                    help: "Hard cap per utterance.")
            }
            .padding(.top, 4)
        }
        .font(.caption)
    }

    private func slider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>,
                        suffix: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(label).font(.caption2)
                Spacer()
                Text(suffix).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
            Text(help).font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .font(.caption)
        }
    }

    private var talkLabel: String {
        switch convo.state {
        case .listening: return "Stop & Send"
        case .thinking: return "Thinking…"
        default: return "Talk"
        }
    }
    private var micIcon: String {
        convo.state == .listening ? "stop.circle.fill" : "mic.fill"
    }
    private var statusColor: Color {
        switch convo.state {
        case .error, .listening: return .red
        case .idle: return .secondary
        default: return .blue
        }
    }
}

/// Live mic level with the speech threshold marked. Bar turns green when the
/// level is above threshold (i.e. counts as speech) — speak and watch it.
struct LevelMeter: View {
    let level: Float       // dBFS, -160..0
    let threshold: Float   // dBFS
    private let floor: Float = -60
    private func norm(_ db: Float) -> CGFloat {
        CGFloat(max(0, min(1, (db - floor) / (0 - floor))))
    }
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Color.gray.opacity(0.2))
                RoundedRectangle(cornerRadius: 3)
                    .fill(level > threshold ? Color.green : Color.gray.opacity(0.6))
                    .frame(width: w * norm(level))
                Rectangle().fill(Color.red).frame(width: 2).offset(x: w * norm(threshold))
            }
        }
    }
}

struct TurnRow: View {
    let turn: Turn
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(turn.speaker)
                .font(.caption2).bold()
                .foregroundStyle(turn.speaker == "You" ? Color.secondary : Color.blue)
            Text(turn.text)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
