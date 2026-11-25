import AppKit
import SwiftUI

@MainActor
struct GroupEditor: View {
    let groupID: UUID
    @ObservedObject var workspace: RoutingWorkspace
    @ObservedObject var groups: SpeakerGroups
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var members: Set<Receiver.ID> = []
    @State private var draftInputs: [GroupInput] = []

    private var group: SpeakerGroup? { groups.groups.first { $0.id == groupID } }
    private var session: SynchronizedGroup? { groups.session(for: groupID) }
    private var editingOutputs: Bool { workspace.airPlay.runs[.saved(groupID)] == nil && session?.active != true }
    private var available: Set<Receiver.ID> {
        Set(workspace.destinations.compactMap { if case .airplay(let id) = $0 { id } else { nil } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(group == nil ? "New Group" : "Edit \(group?.name ?? "")")
                        .font(.title2.weight(.semibold))
                    TextField("Name", text: $name)
                        .accessibilityLabel("Group Name")
                    outputChoices
                    if group == nil {
                        Divider()
                        GroupSourceList(workspace: workspace, inputs: $draftInputs)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                if group != nil {
                    Button("Delete Group", role: .destructive) {
                        groups.remove(groupID)
                        dismiss()
                    }
                    .buttonStyle(TextActionStyle())
                    .disabled(!editingOutputs)
                }
                Spacer()
                Button(group == nil ? "Cancel" : "Close") { dismiss() }
                Button(group == nil ? "Create Group" : "Done", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(members.isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(14)
        }
        .frame(minWidth: 465, idealWidth: 530, minHeight: 330, idealHeight: 460)
        .task {
            name = group?.name ?? ""
            members = group?.members ?? []
            workspace.start()
        }
    }

    private var outputChoices: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionTitle("Outputs")
                if !editingOutputs { Text("Stop the group to change its outputs.").font(.caption).foregroundStyle(.secondary) }
            }
            let devices = available.union(members).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            ForEach(devices, id: \.self) { receiver in
                Toggle(isOn: Binding(
                    get: { members.contains(receiver) },
                    set: { included in
                        if included { members.insert(receiver) } else { members.remove(receiver) }
                    }
                )) {
                    Label(receiver.name + (available.contains(receiver) ? "" : " · unavailable"),
                          systemImage: workspace.discovery.outputSymbol(for: receiver))
                }
                .toggleStyle(.checkbox)
                .disabled(!editingOutputs)
            }
            if devices.isEmpty { Text("Searching for AirPlay outputs…").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }

    private func save() {
        var saved = group ?? SpeakerGroup(id: groupID, name: name, members: members, source: nil)
        saved.name = name
        if editingOutputs { saved.members = members }
        if group == nil { saved.setInputs(draftInputs) }
        groups.save(saved)
        dismiss()
    }
}

@MainActor
struct GroupSourcesWindow: View {
    let groupID: UUID
    @ObservedObject var workspace: RoutingWorkspace
    @ObservedObject var groups: SpeakerGroups
    @Environment(\.dismiss) private var dismiss

    private var group: SpeakerGroup? { groups.groups.first { $0.id == groupID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let group {
                Text("Sources for \(group.name)")
                    .font(.title2.weight(.semibold))
                    .padding([.top, .horizontal], 18)
                ScrollView {
                    let stream = groups.session(for: groupID)?.stream
                    GroupSourceList(workspace: workspace, inputs: Binding(
                        get: { self.group?.configuredInputs ?? [] },
                        set: { workspace.updateGroupInputs($0, in: groupID) }
                    ), statuses: stream?.mixStatus ?? [:], running: stream?.active == true)
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("Group unavailable")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(minWidth: 465, minHeight: 260)
        .task { workspace.start() }
    }
}

@MainActor
private struct GroupSourceList: View {
    @ObservedObject var workspace: RoutingWorkspace
    @Binding var inputs: [GroupInput]
    var statuses: [String: MixInputStatus] = [:]
    var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            inputSection("Apps", kind: .app, available: workspace.apps.map {
                SavedGroupSource(kind: .app, identifier: $0.bundleID ?? $0.name, name: $0.name)
            })
            Divider()
            inputSection("Audio Devices", kind: .device, available: workspace.inputs.map {
                SavedGroupSource(kind: .device, identifier: $0.uid, name: $0.name)
            })
        }
    }

    private func inputSection(_ title: String, kind: SavedGroupSource.Kind,
                              available: [SavedGroupSource]) -> some View {
        var seen = Set<String>()
        let configured = inputs.map(\.source).filter { $0.kind == kind }
        let sources = (configured + available).filter { seen.insert($0.id).inserted }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        return VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            if sources.isEmpty {
                Text("No sources available").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(sources) { source in
                inputRow(source, input: inputs.first { $0.id == source.id })
            }
        }
    }

    private func inputRow(_ source: SavedGroupSource, input: GroupInput?) -> some View {
        let status = statuses[source.id]
        let statusText = if input?.muted == true { "Muted" }
            else if let error = status?.error { error }
            else if status?.hasSignal == true { "Signal detected" }
            else if source.choice(apps: workspace.apps, inputs: workspace.inputs) == nil { "Unavailable" }
            else if running && input != nil { "No signal" }
            else { "" }

        return HStack(spacing: 10) {
            Toggle(isOn: Binding(
                get: { inputs.contains { $0.id == source.id } },
                set: { enabled in
                    if enabled {
                        guard !inputs.contains(where: { $0.id == source.id }) else { return }
                        inputs.append(GroupInput(source: source, gain: 60))
                    } else {
                        inputs.removeAll { $0.id == source.id }
                    }
                }
            )) {
                HStack(spacing: 7) {
                    SourceIdentityIcon(source: source, workspace: workspace)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.name).lineLimit(1).help(source.name)
                        if !statusText.isEmpty {
                            Text(statusText).font(.caption)
                                .foregroundStyle(status?.hasSignal == true && input?.muted == false ? Color.green : .secondary)
                                .lineLimit(1).help(statusText)
                        }
                    }
                }
            }
            .toggleStyle(.checkbox)
            .frame(width: input == nil ? nil : 180, alignment: .leading)
            if let input {
                Slider(value: Binding(
                    get: { input.gain },
                    set: { value in update(input.id) { $0.gain = value.rounded() } }
                ), in: 0...100) {
                    Text("\(source.name) level")
                }
                .labelsHidden()
                .accessibilityLabel("\(source.name) level")
                .disabled(input.muted)
                Text("\(Int(input.gain.rounded()))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                Button {
                    update(input.id) { $0.muted.toggle() }
                } label: {
                    Image(systemName: input.muted ? "speaker.slash" : "speaker.wave.2")
                }
                .accessibilityLabel(input.muted ? "Unmute \(source.name)" : "Mute \(source.name)")
                .help(input.muted ? "Unmute" : "Mute")
            }
        }
        .buttonStyle(.borderless)
        .contextMenu {
            if let input, source.kind == .app {
                Button(input.playLocally ? "Stop Playing on This Mac" : "Also Play on This Mac") {
                    update(input.id) { $0.playLocally.toggle() }
                }
            }
        }
    }

    private func update(_ id: String, _ change: (inout GroupInput) -> Void) {
        var updated = inputs
        guard let index = updated.firstIndex(where: { $0.id == id }) else { return }
        change(&updated[index])
        inputs = updated
    }
}

@MainActor
struct SourceIdentityIcon: View {
    let source: SavedGroupSource
    let workspace: RoutingWorkspace

    private var appIcon: NSImage? {
        guard source.kind == .app else { return nil }
        if let app = workspace.apps.first(where: { ($0.bundleID ?? $0.name) == source.identifier }),
           let icon = NSRunningApplication(processIdentifier: app.id)?.icon { return icon }
        if let bundle = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.identifier) {
            return NSWorkspace.shared.icon(forFile: bundle.path)
        }
        return nil
    }

    var body: some View {
        Group {
            if let appIcon {
                Image(nsImage: appIcon).resizable().scaledToFit()
            } else {
                let symbol = workspace.inputs.first { $0.uid == source.identifier }?.symbol
                Image(systemName: source.kind == .app ? "app" : (symbol ?? "waveform"))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 19, height: 19)
        .accessibilityHidden(true)
    }
}
