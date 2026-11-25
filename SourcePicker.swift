import CoreAudio
import SwiftUI

@MainActor
struct RouteSourcePicker: View {
    let title: String
    let apps: [RunningAudioApp]
    let inputs: [AudioInput]
    @Binding var selection: RouteSourceChoice?
    var unavailableName: String? = nil
    var compact = false
    @State private var showing = false

    var body: some View {
        HStack(spacing: 8) {
            if compact {
                pickerButton.buttonStyle(TextActionStyle(linkColor: true))
            } else {
                Text(title)
                pickerButton
            }
        }
    }

    private var pickerButton: some View {
        Button {
            showing.toggle()
        } label: {
            HStack(spacing: 7) {
                Text(compact && selection == nil ? (unavailableName ?? "Choose Source…") : selectedName)
                    .lineLimit(1)
                if !compact {
                    Image(systemName: "chevron.up.chevron.down").imageScale(.small)
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityLabel(title)
        .accessibilityValue(selectedName)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            SourceChoices(inputs: inputs, selection: $selection) { showing = false }
        }
    }

    private var selectedName: String {
        switch selection {
        case .application(let pid): apps.first(where: { $0.id == pid })?.name ?? "App is closed"
        case .device(let id): inputs.first(where: { $0.id == id })?.name ?? "Device unavailable"
        case nil: unavailableName ?? "Choose"
        }
    }
}

struct TextActionStyle: ButtonStyle {
    var linkColor = false

    func makeBody(configuration: Configuration) -> some View {
        TextActionLabel(label: configuration.label, linkColor: linkColor, pressed: configuration.isPressed)
    }
}

private struct TextActionLabel<Content: View>: View {
    let label: Content
    let linkColor: Bool
    let pressed: Bool
    @State private var hovering = false
    @Environment(\.isFocused) private var focused

    var body: some View {
        label
            .foregroundStyle(linkColor ? Color.accentColor : Color.primary)
            .opacity(pressed ? 0.65 : 1)
            .overlay(alignment: .bottom) {
                if hovering || focused {
                    GeometryReader { proxy in
                        Path { line in
                            line.move(to: CGPoint(x: 0, y: proxy.size.height))
                            line.addLine(to: CGPoint(x: proxy.size.width, y: proxy.size.height))
                        }
                        .stroke(.secondary, style: StrokeStyle(lineWidth: 1, dash: [1, 2]))
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

@MainActor
func verifyAppSignals(feeder: String, file: String) async {
    let trigger = FileManager.default.temporaryDirectory.appendingPathComponent("room-audio-signal-\(UUID())")
    let source = Process()
    var passed = false
    do {
        source.executableURL = URL(fileURLWithPath: feeder)
        source.arguments = [file, trigger.path]
        try source.run()
        let pid = source.processIdentifier
        func outputClients() -> [AudioObjectID] {
            ((try? ProcessAudioClient.snapshot()) ?? []).filter { $0.pid == pid && $0.outputActive }.map(\.object)
        }
        var clients: [AudioObjectID] = []
        for _ in 0..<30 {
            clients = outputClients()
            if !clients.isEmpty { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard !clients.isEmpty else { throw StreamError("Test player did not open its output") }
        let meter = try AppSignalMeter(processes: clients)
        try await Task.sleep(for: .seconds(1))
        guard !meter.takeSignal(), !outputClients().isEmpty else { throw StreamError("Silent output was not detected") }
        print("OPEN_OUTPUT_WITHOUT_SIGNAL")
        try Data().write(to: trigger)
        var hasSignal = false
        for _ in 0..<15 {
            try await Task.sleep(for: .milliseconds(100))
            if meter.takeSignal() { hasSignal = true; break }
        }
        guard hasSignal else { throw StreamError("Playback did not produce a detectable signal") }
        print("OPEN_OUTPUT_WITH_SIGNAL")
        try await Task.sleep(for: .seconds(3))
        _ = meter.takeSignal()
        try await Task.sleep(for: .milliseconds(350))
        guard !meter.takeSignal(), !outputClients().isEmpty else { throw StreamError("Output should remain open after the clip") }
        print("SIGNAL_CLEARED_OUTPUT_STILL_OPEN")
        passed = true
    } catch {
        print("APP_SIGNAL_TEST_FAILED: \(error.localizedDescription)")
    }
    if source.isRunning { source.terminate() }
    try? FileManager.default.removeItem(at: trigger)
    exit(passed ? 0 : 1)
}

@MainActor
private struct SourceChoices: View {
    let inputs: [AudioInput]
    @Binding var selection: RouteSourceChoice?
    let close: () -> Void
    @State private var apps: [RunningAudioApp] = []
    @State private var playing: Set<pid_t> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    choice("Choose", nil)
                    section("Apps")
                    ForEach(apps) { app in
                        let signal = playing.contains(app.id)
                        choice(app.name, .application(app.id),
                               icon: signal ? "speaker.wave.2.fill" : app.hasActiveOutput ? "speaker.fill" : nil,
                               signal: signal,
                               value: signal ? "Playing audio" : app.hasActiveOutput ? "Audio output open" : "")
                    }
                    section("Audio Devices")
                    ForEach(inputs) { input in choice(input.name, .device(input.id)) }
                }
                .padding(10)
            }
            Divider()
            HStack(spacing: 15) {
                Label("Output Open", systemImage: "speaker.fill")
                Label("Playing audio", systemImage: "speaker.wave.2.fill")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(10)
            .accessibilityHidden(true)
        }
        .frame(width: 310, height: 355)
        .task { await watch() }
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.top, 9).padding(.leading, 28)
            .accessibilityAddTraits(.isHeader)
    }

    private func choice(_ title: String, _ source: RouteSourceChoice?, icon: String? = nil,
                        signal: Bool = false, value: String = "") -> some View {
        Button {
            selection = source
            close()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "checkmark")
                    .opacity(selection == source ? 1 : 0).frame(width: 16)
                Text(title).lineLimit(1)
                Spacer()
                if let icon {
                    Image(systemName: icon)
                        .foregroundStyle(signal ? Color.accentColor : .secondary)
                        .frame(width: 24)
                }
            }
            .padding(.vertical, 5).padding(.horizontal, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityAddTraits(selection == source ? .isSelected : [])
    }

    private func watch() async {
        struct Entry {
            let objects: [AudioObjectID]
            let meter: AppSignalMeter?
            var lastSignal: ContinuousClock.Instant?
        }
        var meters: [pid_t: Entry] = [:]
        let clock = ContinuousClock()
        while !Task.isCancelled {
            let detected = RunningAudioApp.list()
            let available = Set(detected.filter(\.hasActiveOutput).map(\.id))
            meters = meters.filter { available.contains($0.key) }
            var signals: Set<pid_t> = []
            for app in detected where app.hasActiveOutput {
                if meters[app.id]?.objects != app.activeAudioObjects {
                    meters[app.id] = Entry(objects: app.activeAudioObjects,
                                           meter: try? AppSignalMeter(processes: app.activeAudioObjects))
                }
                if meters[app.id]?.meter?.takeSignal() == true {
                    meters[app.id]?.lastSignal = clock.now
                }
                if let recent = meters[app.id]?.lastSignal, recent.duration(to: clock.now) < .milliseconds(750) {
                    signals.insert(app.id)
                }
            }
            if apps != detected { apps = detected }
            if playing != signals { playing = signals }
            do { try await Task.sleep(for: .milliseconds(225)) } catch { break }
        }
    }
}
