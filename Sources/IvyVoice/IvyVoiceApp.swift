import SwiftUI

@main
struct IvyVoiceApp: App {
    @StateObject private var convo = Conversation()

    var body: some Scene {
        MenuBarExtra("Ivy Voice", systemImage: "waveform.circle") {
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
            Text(convo.state.label)
                .font(.caption)
                .foregroundStyle(statusColor)
            transcriptView
            talkButton
            Text("Hold ⌃⌥ (Control+Option) anywhere to talk, release to send. Or click / Space here.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            footer
        }
        .padding(12)
    }

    private var header: some View {
        HStack {
            Text("Ivy Voice").font(.headline)
            Spacer()
            Picker("", selection: personaBinding) {
                ForEach(Persona.all) { Text($0.name).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 110)
        }
    }

    private var personaBinding: Binding<Persona> {
        Binding(get: { convo.persona }, set: { convo.switchPersona($0) })
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

    private var talkButton: some View {
        Button(action: { convo.toggleTalk() }) {
            Label(talkLabel, systemImage: micIcon)
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .keyboardShortcut(.space, modifiers: [])
        .tint(convo.state == .listening ? .red : .accentColor)
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
