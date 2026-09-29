import Foundation

/// Where a seat's OAuth token is read from, and how it is read.
///
/// A token seat's login does not live in its profile directory: it lives in an
/// OAuth token that the seat's launcher exports, so the gauge has to export it
/// too or the CLI is simply not logged in. Only the path is ever held or
/// said. The value goes from the file straight into one child's environment,
/// and nowhere else: not to stdout, not to a recorded fixture, not into a
/// reason a seat is drawn with.
public enum SeatToken {
    /// The variable the Claude CLI reads a seat's login from.
    public static let variable = "CLAUDE_CODE_OAUTH_TOKEN"

    /// `~/.config/claude-seats/`, where the seat launchers keep their tokens.
    public static var directory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/claude-seats", isDirectory: true)
    }

    public static func file(for seat: SeatID, in directory: URL = SeatToken.directory) -> URL {
        directory.appendingPathComponent("\(seat.rawValue).token")
    }

    /// The default source for a seat, which is that file when it is there. A
    /// seat with no file gets nil, and so behaves exactly as it did before.
    public static func defaultSource(for seat: SeatID,
                                    in directory: URL = SeatToken.directory) -> URL? {
        let file = file(for: seat, in: directory)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    /// The token, or the reason it could not be read. The reason names the
    /// file and never its contents, because the panel's menu and
    /// `seatgauge-cli read` both show it.
    public static func read(_ file: URL) -> Result<String, ProcessFailure> {
        guard let data = FileManager.default.contents(atPath: file.path),
              let text = String(data: data, encoding: .utf8)
        else { return .failure(ProcessFailure("the token file \(file.path) could not be read")) }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty
        else { return .failure(ProcessFailure("the token file \(file.path) is empty")) }
        return .success(token)
    }
}
