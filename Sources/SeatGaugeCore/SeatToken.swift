import Foundation

/// Where a seat's OAuth token is read from, and how it is read.
///
/// A token seat's login does not live in its profile directory: it lives in an
/// OAuth token handed to the CLI in its environment, so the gauge has to hand
/// it over too or the CLI is not logged in. Token seats are optional,
/// and a seat names its file with `token` in `seats.json`. Only the path is
/// ever held or said. The value goes from the file straight into one child's
/// environment, and nowhere else: not to stdout, not to a recorded fixture,
/// not into a reason a seat is drawn with.
public enum SeatToken {
    /// The variable the Claude CLI reads a seat's login from.
    public static let variable = "CLAUDE_CODE_OAUTH_TOKEN"

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
