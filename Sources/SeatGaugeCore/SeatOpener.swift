import Foundation

/// Runs a seat's `open` command when its card is clicked: the argv as
/// written, no shell, detached. It is watched only for a short start check,
/// so a command that would not start, or quit at once with a failure, comes
/// back as one line the title bar can show. Anything still running after the
/// check is left to run, and a terminal it opened outlives the panel.
public struct SeatOpener: Sendable {
    /// What a login shell would find without any profile: Homebrew and the
    /// usual per-user bin first, then the system's. Set outright, so the PATH
    /// the app was launched with never decides which program runs.
    public static let defaultPath = (["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin"]
                                     + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")

    /// The variables a launcher needs to find its user and their files. The
    /// rest of the app's environment, a key exported in the launching shell
    /// included, never reaches it.
    static let inherited = ["HOME", "USER", "LANG"]

    let parent: [String: String]
    let settle: Duration

    public init(parent: [String: String] = ProcessInfo.processInfo.environment, settle: Duration = .seconds(3)) {
        self.parent = parent
        self.settle = settle
    }

    public static func environment(from parent: [String: String]) -> [String: String] {
        var environment = parent.filter { inherited.contains($0.key) }
        environment["PATH"] = defaultPath
        return environment
    }

    /// Returns once the command has exited cleanly or outlasted the start
    /// check; throws `ProcessFailure` in the title bar's words otherwise.
    public func open(_ seat: Seat) async throws {
        guard let words = seat.open, let program = words.first else { return }
        let name = URL(fileURLWithPath: program).lastPathComponent
        // One line whatever the label, program or system said holds.
        let failure = { (why: String) in
            ProcessFailure("Open \(seat.label): \(name) \(why)".split(whereSeparator: \.isNewline).joined(separator: " "))
        }
        let environment = Self.environment(from: parent)
        guard let executable = Self.locate(program, path: environment["PATH"] ?? "") else {
            throw failure("would not start: it is not on the PATH")
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = Array(words.dropFirst())
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let (exits, exited) = AsyncStream.makeStream(of: Int32.self)
        process.terminationHandler = { exited.yield($0.terminationStatus); exited.finish() }
        do { try process.run() } catch {
            throw failure("would not start: " + error.localizedDescription)
        }

        let status = await withTaskGroup(of: Int32?.self) { group in
            group.addTask { await exits.first { _ in true } }
            group.addTask { [settle] in try? await Task.sleep(for: settle); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        if let status, status != 0 { throw failure("exited with status \(status)") }
    }

    /// A program with a slash is a path; a bare name is looked up on `path`,
    /// as a shell would, since `Process` takes a file and not a name.
    static func locate(_ program: String, path: String) -> URL? {
        if program.contains("/") { return URL(fileURLWithPath: program) }
        return path.split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent(program) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
