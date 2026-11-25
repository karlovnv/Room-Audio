import CryptoKit
import Darwin
import Foundation

private let service = "local.roomaudio.ptp"
private let installedDirectory = "/Library/Application Support/Room Audio PTP"
private let installedPlist = "/Library/LaunchDaemons/\(service).plist"
private let transportHash = "de19cc204837640301061a088459ed72e2aa10a352c9040f9e26f9dbb10f7c3a"

@objc private protocol ClockService {
    func start(_ address: String, reply: @escaping (String?) -> Void)
    func stop(reply: @escaping () -> Void)
}

private final class ClockDaemon: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let uid: uid_t
    private let lock = NSLock()
    private var owner: NSXPCConnection?
    private var clock: Process?

    init(uid: uid_t) { self.uid = uid }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == uid else { return false }
        let client = ClockClientSession(daemon: self, connection: connection)
        connection.exportedInterface = NSXPCInterface(with: ClockService.self)
        connection.exportedObject = client
        connection.invalidationHandler = { [weak self, weak connection] in
            if let connection { self?.stop(connection) }
        }
        connection.activate()
        return true
    }

    func start(_ address: String, for connection: NSXPCConnection) -> String? {
        guard localAddress(address) else { return "PTP requires a local IPv4 interface address." }
        return lock.withLock {
            if owner === connection, clock?.isRunning == true { return nil }
            guard clock?.isRunning != true else { return "The PTP service is already in use by another session." }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: installedDirectory + "/cliairplay")
            process.arguments = ["--ptp-daemon", "--if", address]
            process.environment = ["PATH": "/usr/bin:/bin", "HOME": installedDirectory]
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
                owner = connection
                clock = process
                return nil
            } catch {
                return "Could not start the PTP clock: \(error.localizedDescription)"
            }
        }
    }

    func stop(_ connection: NSXPCConnection) {
        lock.withLock {
            guard owner === connection else { return }
            owner = nil
            guard let process = clock, process.isRunning else {
                clock = nil
                return
            }
            process.terminate()
            let deadline = DispatchTime.now().uptimeNanoseconds + 1_500_000_000
            while process.isRunning && DispatchTime.now().uptimeNanoseconds < deadline { usleep(25_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            clock = nil
        }
    }

    private func localAddress(_ address: String) -> Bool {
        var requested = in_addr()
        guard inet_pton(AF_INET, address, &requested) == 1 else { return false }
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return false }
        defer { freeifaddrs(list) }
        var current = list
        while let entry = current {
            let value = entry.pointee
            if let pointer = value.ifa_addr, pointer.pointee.sa_family == AF_INET,
               value.ifa_flags & UInt32(IFF_UP) != 0, value.ifa_flags & UInt32(IFF_LOOPBACK) == 0 {
                let actual = UnsafeRawPointer(pointer).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                if actual.s_addr == requested.s_addr { return true }
            }
            current = value.ifa_next
        }
        return false
    }
}

private final class ClockClientSession: NSObject, ClockService {
    let daemon: ClockDaemon
    weak var connection: NSXPCConnection?

    init(daemon: ClockDaemon, connection: NSXPCConnection) {
        self.daemon = daemon
        self.connection = connection
    }

    func start(_ address: String, reply: @escaping (String?) -> Void) {
        guard let connection else { reply("The connection to the PTP service is closed."); return }
        reply(daemon.start(address, for: connection))
    }

    func stop(reply: @escaping () -> Void) {
        if let connection { daemon.stop(connection) }
        reply()
    }
}

private func connect(address: String) -> Int32 {
    let connection = NSXPCConnection(machServiceName: service, options: .privileged)
    connection.remoteObjectInterface = NSXPCInterface(with: ClockService.self)
    connection.activate()
    defer { connection.invalidate() }
    // A synchronous proxy waits for the launchd job to start and the requested
    // operation to complete. Python independently waits for clock readiness.
    var problem: String?
    let proxy = connection.synchronousRemoteObjectProxyWithErrorHandler { error in
        problem = error.localizedDescription
    } as! ClockService
    proxy.start(address) { problem = $0 }
    if let problem {
        // Older installed daemons can still return these Russian messages over XPC.
        let messages = [
            "PTP требует локальный IPv4-адрес интерфейса.": "PTP requires a local IPv4 interface address.",
            "Служба PTP уже обслуживает другую сессию.": "The PTP service is already in use by another session.",
            "Соединение со службой PTP закрыто.": "The connection to the PTP service is closed."
        ]
        let message = messages[problem] ?? problem.replacingOccurrences(
            of: "Не удалось запустить часы PTP:", with: "Could not start the PTP clock:")
        FileHandle.standardError.write(Data((message + "\n").utf8))
        return 1
    }
    _ = FileHandle.standardInput.readDataToEndOfFile()
    proxy.stop {}
    return 0
}

private func install(transport: String) throws {
    guard getuid() != 0 else { throw CocoaError(.userCancelled) }
    let helper = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
    let digest = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: helper))).map {
        String(format: "%02x", $0)
    }.joined()
    let manifest: [String: Any] = [
        "Label": service, "MachServices": [service: true],
        "ProgramArguments": [installedDirectory + "/PTPService", "--daemon", String(getuid())]
    ]
    let xml = try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0)
    let script = """
    set -eu
    umask 077
    directory='/Library/Application Support/Room Audio PTP'
    plist='/Library/LaunchDaemons/local.roomaudio.ptp.plist'
    test ! -e "$directory"
    test ! -e "$plist"
    stage=$(/usr/bin/mktemp -d '/Library/Application Support/.roomaudio-ptp.XXXXXXXX')
    moved=0
    /bin/chmod 700 "$stage"
    trap 'if [ "$moved" = 1 ]; then /bin/rm -f "$plist" "$directory/PTPService" "$directory/cliairplay"; /bin/rmdir "$directory"; fi; /bin/rm -f "$stage/PTPService" "$stage/cliairplay" "$stage/service.plist"; /bin/rmdir "$stage" 2>/dev/null || true' EXIT
    /bin/cp \(quoted(helper)) "$stage/PTPService"
    /bin/cp \(quoted(transport)) "$stage/cliairplay"
    printf '%s  %s\n' '\(digest)' "$stage/PTPService" '\(transportHash)' "$stage/cliairplay" | /usr/bin/shasum -a 256 -c --status
    /bin/cat > "$stage/service.plist" <<'ROOM_AUDIO_PTP_PLIST'
    \(String(decoding: xml, as: UTF8.self))
    ROOM_AUDIO_PTP_PLIST
    /usr/sbin/chown -R root:wheel "$stage"
    /bin/chmod 755 "$stage" "$stage/PTPService" "$stage/cliairplay"
    /bin/chmod 644 "$stage/service.plist"
    /bin/mkdir -m 755 "$directory"
    moved=1
    /usr/sbin/chown root:wheel "$directory"
    /bin/mv "$stage/PTPService" "$stage/cliairplay" "$directory/"
    /bin/mv "$stage/service.plist" "$plist"
    /bin/launchctl bootstrap system "$plist"
    moved=0
    """
    let approval = """
    on run argv
        do shell script (item 1 of argv) with prompt "Room Audio needs administrator approval to install the AirPlay sync service." with administrator privileges
    end run
    """
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", approval, script]
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 { throw CocoaError(.fileWriteNoPermission) }
}

private func quoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}

let arguments = CommandLine.arguments
do {
    if arguments.count == 3, arguments[1] == "--daemon", geteuid() == 0, let uid = uid_t(arguments[2]), uid != 0 {
        let daemon = ClockDaemon(uid: uid)
        let listener = NSXPCListener(machServiceName: service)
        listener.delegate = daemon
        listener.resume()
        withExtendedLifetime(daemon) { RunLoop.main.run() }
    } else if arguments.count == 3, arguments[1] == "--connect", geteuid() != 0 {
        exit(connect(address: arguments[2]))
    } else if arguments.count == 3, arguments[1] == "--install", geteuid() != 0 {
        try install(transport: arguments[2])
    } else {
        exit(64)
    }
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
