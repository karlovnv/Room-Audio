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
    @State private var adding = false

    private var group: SpeakerGroup? { groups.groups.first { $0.id == groupID } }
    private var session: SynchronizedGroup? { groups.session(for: groupID) }
    private var editingOutputs: Bool { session?.active != true && !workspace.recoveringGroups.contains(groupID) }
    private var inputs: [GroupInput] { group?.configuredInputs ?? draftInputs }
    private var available: Set<Receiver.ID> {
        Set(workspace.destinations.compactMap { if case .airplay(let id) = $0 { id } else { nil } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(group == nil ? "Новая группа" : "Группа «\(group?.name ?? "")»")
                        .font(.title2.weight(.semibold))
                    TextField("Название", text: $name)
                        .accessibilityLabel("Название группы")
                    mixer
                    Divider()
                    outputChoices
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                if group != nil {
                    Button("Удалить группу", role: .destructive) {
                        groups.remove(groupID)
                        dismiss()
                    }
                    .buttonStyle(TextActionStyle())
                    .disabled(!editingOutputs)
                }
                Spacer()
                Button(group == nil ? "Отмена" : "Закрыть") { dismiss() }
                Button(group == nil ? "Создать группу" : "Готово", action: save)
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

    private var mixer: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                sectionTitle("Источники")
                Spacer()
                Button("Добавить источник…") { adding.toggle() }
                    .buttonStyle(TextActionStyle(linkColor: true))
                    .popover(isPresented: $adding, arrowEdge: .bottom) {
                        GroupSourceChoices(workspace: workspace, included: Set(inputs.map(\.id))) { selected in
                            apply(inputs + selected.map { GroupInput(source: $0, gain: 60) })
                            adding = false
                        }
                    }
            }
            inputSection("Приложения", kind: .app)
            Divider()
            inputSection("Аудиоустройства", kind: .device)
        }
    }

    private func inputSection(_ title: String, kind: SavedGroupSource.Kind) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(title)
            let selected = inputs.filter { $0.source.kind == kind }
            if selected.isEmpty {
                Text("Пока ничего не добавлено").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(selected) { input in
                inputRow(input)
            }
        }
    }

    private func inputRow(_ input: GroupInput) -> some View {
        let status = session?.stream.mixStatus[input.id]
        let running = session?.stream.active == true
        let statusText = if input.muted { "Приглушён" }
            else if let error = status?.error { error }
            else if status?.hasSignal == true { "Есть сигнал" }
            else if running { "Нет сигнала" }
            else if input.source.choice(apps: workspace.apps, inputs: workspace.inputs) == nil { "Недоступен" }
            else { "" }

        return HStack(spacing: 9) {
            SourceIdentityIcon(source: input.source, workspace: workspace)
            VStack(alignment: .leading, spacing: 2) {
                Text(input.source.name).lineLimit(1).help(input.source.name)
                if !statusText.isEmpty {
                    Text(statusText).font(.caption).foregroundStyle(status?.hasSignal == true && !input.muted ? Color.green : .secondary)
                        .lineLimit(1).help(statusText)
                }
            }
            .frame(width: 129, alignment: .leading)
            Slider(value: Binding(
                get: { input.gain },
                set: { value in update(input.id) { $0.gain = value.rounded() } }
            ), in: 0...100) {
                Text("Уровень \(input.source.name)")
            }
            .labelsHidden()
            .accessibilityLabel("Уровень \(input.source.name)")
            .disabled(input.muted)
            Text("\(Int(input.gain.rounded()))%").monospacedDigit().frame(width: 40, alignment: .trailing)
            Button {
                update(input.id) { $0.muted.toggle() }
            } label: {
                Image(systemName: input.muted ? "speaker.slash" : "speaker.wave.2")
            }
            .accessibilityLabel(input.muted ? "Включить \(input.source.name)" : "Приглушить \(input.source.name)")
            .help(input.muted ? "Включить" : "Приглушить")
            Button {
                apply(inputs.filter { $0.id != input.id })
            } label: { Image(systemName: "xmark") }
            .accessibilityLabel("Убрать \(input.source.name)")
            .help("Убрать из группы")
        }
        .buttonStyle(.borderless)
        .contextMenu {
            if input.source.kind == .app {
                Button(input.playLocally ? "Выключить звук приложения на Mac" : "Также на Mac") {
                    update(input.id) { $0.playLocally.toggle() }
                }
            }
        }
    }

    private var outputChoices: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionTitle("Выходы")
                if !editingOutputs { Text("Состав можно изменить после остановки").font(.caption).foregroundStyle(.secondary) }
            }
            let devices = available.union(members).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            ForEach(devices, id: \.self) { receiver in
                Toggle(isOn: Binding(
                    get: { members.contains(receiver) },
                    set: { included in
                        if included { members.insert(receiver) } else { members.remove(receiver) }
                    }
                )) {
                    Label(receiver.name + (available.contains(receiver) ? "" : " · недоступна"), systemImage: "airplay.audio")
                }
                .toggleStyle(.checkbox)
                .disabled(!editingOutputs)
            }
            if devices.isEmpty { Text("Поиск AirPlay-выходов…").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }

    private func apply(_ updated: [GroupInput]) {
        if group == nil { draftInputs = updated }
        else { workspace.updateGroupInputs(updated, in: groupID) }
    }

    private func update(_ id: String, _ change: (inout GroupInput) -> Void) {
        var updated = inputs
        guard let index = updated.firstIndex(where: { $0.id == id }) else { return }
        change(&updated[index])
        apply(updated)
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

@MainActor
private struct GroupSourceChoices: View {
    @ObservedObject var workspace: RoutingWorkspace
    let included: Set<String>
    let add: ([SavedGroupSource]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected = Set<String>()

    private var apps: [SavedGroupSource] {
        var seen = Set<String>()
        return workspace.apps.compactMap { app in
            let source = SavedGroupSource(kind: .app, identifier: app.bundleID ?? app.name, name: app.name)
            return seen.insert(source.id).inserted ? source : nil
        }
    }

    private var devices: [SavedGroupSource] {
        workspace.inputs.map { SavedGroupSource(kind: .device, identifier: $0.uid, name: $0.name) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    choices("Приложения", sources: apps)
                    Divider()
                    choices("Аудиоустройства", sources: devices)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                Button("Добавить") { add((apps + devices).filter { selected.contains($0.id) }) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty)
            }
            .padding(10)
        }
        .frame(width: 340, height: 365)
    }

    private func choices(_ title: String, sources: [SavedGroupSource]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(sources) { source in
                let alreadyAdded = included.contains(source.id)
                Toggle(isOn: Binding(
                    get: { alreadyAdded || selected.contains(source.id) },
                    set: { checked in
                        if checked { selected.insert(source.id) } else { selected.remove(source.id) }
                    }
                )) {
                    HStack(spacing: 7) {
                        SourceIdentityIcon(source: source, workspace: workspace)
                        Text(source.name).lineLimit(1)
                        if alreadyAdded { Text("Добавлен").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(alreadyAdded)
            }
        }
    }
}
