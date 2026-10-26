import Foundation

/// How the app writes the files it keeps: `seats.json`, the readings,
/// `headroom.json`, `spend.csv`, `state.json`, `attribution.json`,
/// `machines.json`, `log.json` and the backups. They name the user's clients,
/// repositories, sessions and usage, so each is readable by the user alone
/// (600) in a folder only the user can open (700), whatever the umask. A
/// file or folder an older build left wider is narrowed the next time one is
/// written there.
public enum PrivateFile {
    /// Makes `folder`, and any folder above it that is missing, 700, and
    /// narrows `folder` itself if it is already there.
    public static func folder(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        narrow(folder)
    }

    /// Replaces `file` with `data` in one rename, so a reader sees the old
    /// file or the new one, and never a file anyone else could read: the data
    /// is written to a new 600 file beside it first. Its folder is made when
    /// `makingFolder` says so, as the caller always did, and narrowed either
    /// way.
    public static func write(_ data: Data, to file: URL, makingFolder: Bool = false) throws {
        let folder = file.deletingLastPathComponent()
        if makingFolder { try self.folder(folder) } else { narrow(folder) }
        let draft = folder.appendingPathComponent(".\(file.lastPathComponent).\(UUID().uuidString)")
        try create(data, at: draft)
        guard rename(draft.path, file.path) == 0 else {
            let problem = failure(file)
            unlink(draft.path)
            throw problem
        }
    }

    /// Writes `data` to a new 600 file at `file`, refusing one that is there
    /// already, a link included.
    public static func create(_ data: Data, at file: URL) throws {
        let descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw failure(file) }
        var written = fchmod(descriptor, 0o600) == 0
        var rest = data[...]
        while written, !rest.isEmpty {
            let count = rest.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            written = count > 0
            if written { rest = rest.dropFirst(count) }
        }
        var problem = written ? nil : failure(file)
        if close(descriptor) != 0, problem == nil { problem = failure(file) }
        if let problem {
            unlink(file.path)
            throw problem
        }
    }

    /// Takes group and other access off something of the user's own. A
    /// folder of someone else's, such as a shared temporary one, is left alone.
    static func narrow(_ url: URL) {
        var info = stat()
        guard stat(url.path, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 != 0 else { return }
        chmod(url.path, info.st_mode & 0o700)
    }

    private static func failure(_ url: URL) -> CocoaError {
        CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path,
                                                  NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)])
    }
}
