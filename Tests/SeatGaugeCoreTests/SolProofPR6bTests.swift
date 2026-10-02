import Foundation
import Testing

import SeatGaugeCore

/// `spot` undoes a written `..` by name, which is how the CLI joins names onto
/// `CLAUDE_CONFIG_DIR`. The gauge's own reads do not: `ClaudePlanFile.file`
/// appends `.claude.json` to the profile URL as written, and the file system
/// walks `link/..` from where the link points. So `~/a/sub/..`, with `~/a/sub`
/// a link to a folder in `~`, is `~/a` to `spot` and `~` to the gauge, which
/// then reads the default login's `~/.claude.json` as this seat's, and
/// `IdentityObserver` names this seat as the default login.
@Suite struct SolProofPR6bTests {

    @Test("Sol proof, criterion 2: a profile whose dot-dot past a link lands on the default login or another seat's profile when the gauge reads it is still refused")
    func dotDotThatTheGaugeReadsOntoTheDefaultLoginIsRefused() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-sol-b-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        for folder in ["a", "elsewhere", "profiles/work"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        // `~/a/sub` is a link to `~/elsewhere`, so `~/a/sub/..` is `~` to the file system.
        try FileManager.default.createSymbolicLink(atPath: home.path + "/a/sub", withDestinationPath: home.path + "/elsewhere")
        let account = #"{ "oauthAccount": { "accountUuid": "the-default-login", "organizationType": "claude_max" } }"#
        try Data(account.utf8).write(to: home.appendingPathComponent(".claude.json"))
        try Data(#"{ "oauthAccount": { "accountUuid": "the-work-seat" } }"#.utf8)
            .write(to: home.appendingPathComponent("profiles/work/.claude.json"))

        func decode(_ seats: [String]) -> Result<Config, ConfigProblem> {
            let text = "{ \"seats\": [\(seats.joined(separator: ", "))] }"
            do {
                return .success(try ConfigLoader.decode(Data(text.utf8), tokenDirectory: home.appendingPathComponent("tokens"), home: home))
            } catch let problem as ConfigProblem { return .failure(problem) } catch { return .failure(ConfigProblem("\(error)")) }
        }
        func claude(_ id: String, _ profile: String) -> String {
            #"{ "id": "\#(id)", "label": "\#(id)", "kind": "claude", "profile": "\#(profile)", "login": "own" }"#
        }

        // The gauge's own read of this profile lands on the default login's file.
        for profile in [home.path + "/a/sub/.."] {
            let read = ClaudePlanFile.file(profileDir: URL(fileURLWithPath: profile, isDirectory: true), home: home)
            #expect(FileManager.default.contents(atPath: read.path) == Data(account.utf8), "\(profile): the gauge reads somewhere else")
            switch decode([claude("work", profile)]) {
            case let .failure(problem):
                #expect(problem.reason.contains("default login"), "\(profile): \(problem.reason)")
            case let .success(config):
                let seen = IdentityObserver.observe(seats: config.seats, home: home)
                Issue.record("\(profile) accepted; the gauge reads ~/.claude.json as this seat's (plan \(ClaudePlanFile.plan(in: read) ?? "none")), and observes \(seen)")
            }
        }

        // Two seats the gauge reads from one folder: `~/a/sub/../profiles/work` is `~/profiles/work`.
        let other = home.path + "/a/sub/../profiles/work"
        let read = ClaudePlanFile.file(profileDir: URL(fileURLWithPath: other, isDirectory: true), home: home)
        #expect(FileManager.default.contents(atPath: read.path) == FileManager.default.contents(atPath: home.path + "/profiles/work/.claude.json"))
        switch decode([claude("work", home.path + "/profiles/work"), claude("personal", other)]) {
        case let .failure(problem):
            #expect(problem.reason.contains("same profile as \"work\""), "\(problem.reason)")
        case .success:
            Issue.record("\(other) accepted beside \(home.path)/profiles/work; the gauge reads the work seat's login file for both")
        }
    }
}
