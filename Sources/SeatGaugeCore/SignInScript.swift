import Foundation

public enum SignInScript {
    public struct Written: Sendable {
        public let folder: URL
        public let script: URL
        public let marker: URL
    }

    public static func write(helper: URL, seat: String, seatsFile: URL,
                             in parent: URL = FileManager.default.temporaryDirectory) throws -> Written {
        let folder = parent.appendingPathComponent("stub", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appendingPathComponent("sign-in.command")
        try Data("exit 1\n".utf8).write(to: script)
        return Written(folder: folder, script: script, marker: folder.appendingPathComponent("ended"))
    }
}
