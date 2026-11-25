import SwiftUI

@MainActor
struct BluetoothGroupEditor: View {
    let id: UUID
    @ObservedObject var workspace: RoutingWorkspace
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var source: SavedGroupSource?
    @State private var selected: Set<String> = []

    private var group: BluetoothGroup? { workspace.bluetoothGroups.groups.first { $0.id == id } }
    private var active: Bool { workspace.bluetoothGroups.active.contains(id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(group == nil ? "New Bluetooth Group" : "Edit \(group?.name ?? "")")
                        .font(.title2.weight(.semibold))
                    TextField("Name", text: $name).accessibilityLabel("Group Name")
                    sourcePicker(workspace: workspace, source: $source)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Bluetooth Outputs").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        let available = workspace.availableBluetoothOutputs
                        let choices = outputChoices
                        if active {
                            Text("Stop the group to change its outputs.").font(.caption).foregroundStyle(.secondary)
                        } else if choices.isEmpty {
                            Text("Connect a Bluetooth audio output in System Settings.").foregroundStyle(.secondary)
                        }
                        ForEach(choices) { output in
                            Toggle(isOn: Binding(get: { selected.contains(output.uid) }, set: {
                                if $0 { selected.insert(output.uid) } else { selected.remove(output.uid) }
                            })) {
                                Label(output.name + (available[output.uid] == nil ? " · unavailable" : ""),
                                      systemImage: LocalOutput.symbol)
                            }
                            .toggleStyle(.checkbox)
                            .disabled(active)
                        }
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                if group != nil {
                    Button("Delete Group", role: .destructive) {
                        workspace.bluetoothGroups.remove(id)
                        dismiss()
                    }
                    .buttonStyle(TextActionStyle())
                    .disabled(active)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button(group == nil ? "Create Group" : "Done", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(source == nil || (!active && outputChoices.allSatisfy { !selected.contains($0.uid) }) ||
                              name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(14)
        }
        .frame(minWidth: 440, minHeight: 280)
        .task {
            name = group?.name ?? ""
            source = group?.source
            selected = Set(group?.outputs.map(\.uid) ?? [])
            workspace.start()
        }
    }

    private var outputChoices: [BluetoothGroupOutput] {
        let discovered = workspace.availableBluetoothOutputs.values.compactMap(BluetoothGroupOutput.init)
        let settings = Dictionary((group?.outputs ?? []).map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })
        var outputs = settings
        for device in discovered {
            var output = settings[device.uid] ?? device
            output.name = device.name
            outputs[device.uid] = output
        }
        return outputs.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func save() {
        guard let source else { return }
        let outputs = active ? (group?.outputs ?? []) : outputChoices.filter { selected.contains($0.uid) }
        let saved = BluetoothGroup(id: id, name: name, source: source, outputs: outputs)
        guard workspace.bluetoothGroups.save(saved) else { return }
        workspace.reconcileBluetoothGroups()
        dismiss()
    }
}

@MainActor
struct BluetoothGroupRow: View {
    let group: BluetoothGroup
    @ObservedObject var workspace: RoutingWorkspace
    let compact: Bool
    let allowsEditing: Bool
    var showSources: (() -> Void)?
    @Environment(\.openWindow) private var openWindow
    @State private var expanded = false
    @State private var hovering = false

    private var active: Bool { workspace.bluetoothGroups.active.contains(group.id) }
    private var status: BluetoothGroupStatus { workspace.bluetoothGroups.statuses[group.id] ?? .init() }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 12) {
                if compact {
                    CompactDisclosureButton(title: group.name, symbol: "hifispeaker.2", active: status.connected > 0,
                                            emphasized: true, connection: status.connecting || status.reconnecting
                                                ? ConnectionIcon(reconnecting: status.reconnecting) : nil,
                                            showsArrow: hovering, expanded: $expanded)
                } else {
                    Button { expanded.toggle() } label: {
                        HStack(spacing: CompactRouteLayout.iconSpacing) {
                            CompactRouteLayout.icon("hifispeaker.2")
                            Text(group.name).lineLimit(1)
                            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                                .font(.caption2).foregroundStyle(.secondary).accessibilityHidden(true)
                            if status.connecting || status.reconnecting {
                                ConnectionIcon(reconnecting: status.reconnecting)
                            }
                        }
                        .font(.headline)
                    }
                    .buttonStyle(TextActionStyle())
                    .accessibilityValue(expanded ? "Outputs expanded" : "Outputs collapsed")
                    .help(expanded ? "Hide group outputs" : "Show group outputs")
                    .frame(width: CompactRouteLayout.captionWidth, alignment: .leading)
                }
                HStack(spacing: 8) {
                    let maximum = workspace.bluetoothGroupVolumes(group).values.max()
                    VolumeSlider(name: group.name, value: Binding(get: {
                        workspace.bluetoothGroupVolumes(group).values.max() ?? 0
                    }, set: {
                        workspace.setBluetoothGroupVolume($0, group: group)
                    }), showsSignalColumn: false, available: maximum != nil, hidesCaption: true)
                    .disabled(maximum == nil || !active)
                    .opacity(active ? 1 : 0)
                    .accessibilityHidden(!active)
                    Button { workspace.toggleBluetoothGroup(group.id) } label: {
                        transmissionLabel(active ? "Stop Streaming" : "Stream", active: active, compact: compact)
                    }
                    .buttonStyle(.bordered)
                    .frame(width: compact ? 28 : nil)
                    .accessibilityLabel(active ? "Stop \(group.name)" : "Stream to \(group.name)")
                }
            }
            .background(.primary.opacity(compact && hovering ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 7))
            .onHover { hovering = $0 }
            HStack(spacing: 6) {
                if let showSources {
                    Button(group.source.name, action: showSources)
                        .buttonStyle(TextActionStyle(linkColor: true))
                        .lineLimit(1)
                        .accessibilityLabel("Source for \(group.name)")
                        .accessibilityValue(group.source.name)
                } else {
                    sourcePicker(workspace: workspace, source: Binding(get: { group.source }, set: { value in
                        if let value { workspace.updateBluetoothGroupSource(value, in: group.id) }
                    }), compact: true)
                }
                if active {
                    Text("· \(status.connected)/\(group.outputs.count)")
                        .fixedSize()
                        .accessibilityLabel("\(status.connected) of \(group.outputs.count) connected")
                    if let message = status.sourceMessage {
                        Text("· \(message)").lineLimit(1).help(message)
                    } else if status.connected > 0 && !status.hasRecentSignal {
                        Image(systemName: "pause.fill").imageScale(.small)
                            .accessibilityLabel("No audio signal").help("No audio signal")
                    }
                } else if !expanded {
                    let names = group.outputs.map(\.name).joined(separator: " · ")
                    Text("· \(names)").lineLimit(1).help(names)
                }
                if allowsEditing {
                    Spacer(minLength: 4)
                    Button { RoomAudioDelegate.openBluetoothGroupWindow(openWindow, id: group.id) } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Edit group \(group.name)")
                    .help("Edit Group")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, CompactRouteLayout.titleInset)
            if expanded {
                if compact {
                    CompactDetailPanel { members }
                        .padding(.leading, CompactRouteLayout.titleInset)
                } else {
                    members.padding(.leading, CompactRouteLayout.titleInset)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var members: some View {
        ForEach(group.outputs) { output in
            member(output)
        }
    }

    private func member(_ output: BluetoothGroupOutput) -> some View {
        let available = workspace.availableBluetoothOutputs[output.uid] != nil
        let state = status.members[output.uid] ?? (available ? .idle : .unavailable)
        let busy = if case .busy = state { true } else { false }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                CompactRouteLayout.icon(LocalOutput.symbol)
                Text(output.name)
                if state == .connecting || state.isRetrying { ConnectionIcon(reconnecting: state.isRetrying) }
                Text(state.description).foregroundStyle(.secondary).lineLimit(1).help(state.description)
                Spacer()
                if active, state == .stopped {
                    Button("Connect") { workspace.requestBluetoothOutput(output.uid, in: group.id, enabled: true) }
                        .buttonStyle(TextActionStyle(linkColor: true))
                }
            }
            .opacity(available ? 1 : 0.55)
            if allowsEditing {
                adjustment("Volume", output: output, value: Int(workspace.bluetoothVolume(output.uid).rounded()),
                           range: 0...100, display: "\(Int(workspace.bluetoothVolume(output.uid).rounded()))%") {
                    workspace.setBluetoothVolume(Double($0), for: output.uid)
                }
                .disabled(busy)
                let balance = output.balance == 0 ? "Center" : "\(output.balance < 0 ? "L" : "R") \(abs(output.balance))"
                adjustment("Balance", output: output, value: output.balance, range: -100...100, display: balance) { value in
                    changeOutput(output.uid) { $0.balance = value }
                }
                adjustment("Delay", output: output, value: output.delayMilliseconds,
                           range: 0...LocalPlayback.maximumDelayMilliseconds, display: "\(output.delayMilliseconds) ms") { value in
                    changeOutput(output.uid) { $0.delayMilliseconds = value }
                }
            }
        }
        .font(.caption)
    }

    private func adjustment(_ title: String, output: BluetoothGroupOutput, value: Int, range: ClosedRange<Int>,
                            display: String, set: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 48, alignment: .leading)
            Slider(value: Binding(get: { Double(value) }, set: { set(Int($0.rounded())) }),
                   in: Double(range.lowerBound)...Double(range.upperBound), step: 1)
            .accessibilityLabel("\(title) for \(output.name)")
            .accessibilityValue(display)
            Text(display).monospacedDigit().frame(width: 50, alignment: .trailing)
        }
    }

    private func changeOutput(_ uid: String, _ transform: (inout BluetoothGroupOutput) -> Void) {
        guard var output = workspace.bluetoothGroups.groups.first(where: { $0.id == group.id })?
            .outputs.first(where: { $0.uid == uid }) else { return }
        transform(&output)
        workspace.bluetoothGroups.updateOutput(output, in: group.id, volume: Int(workspace.bluetoothVolume(uid).rounded()))
    }
}

@MainActor
private func sourcePicker(workspace: RoutingWorkspace, source: Binding<SavedGroupSource?>, compact: Bool = false) -> some View {
    RouteSourcePicker(title: "Source", apps: workspace.apps, inputs: workspace.inputs, selection: Binding(
        get: { source.wrappedValue?.choice(apps: workspace.apps, inputs: workspace.inputs) },
        set: { choice in
            guard let choice, let saved = SavedGroupSource(choice: choice, apps: workspace.apps, inputs: workspace.inputs) else { return }
            source.wrappedValue = saved
        }
    ), unavailableName: source.wrappedValue?.name, compact: compact, allowsClearing: false, showsSourceIcons: true)
}
