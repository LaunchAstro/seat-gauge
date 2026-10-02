import Foundation
import Testing

import SeatGaugeCore

/// Sol's proofs for PR 3 at 4ec6d0c, against the suite's own fake `claude`.
/// Uncommitted, for the orchestrator.
@Suite struct SolProofPR3bTests {

    @Test("Sol proof, criterion 3: ~/.claude through a symlinked parent is refused when ~/.claude does not exist yet") func dotClaudeThroughASymlinkedParentIsRefused() throws {
        let scratch = try SeatLoginTests.scratch(.accepts("c"))
        defer { scratch.remove() }
        // A link to home, and no ~/.claude yet, as on a fresh machine.
        let link = scratch.home.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: scratch.home)
        let profile = link.appendingPathComponent(".claude", isDirectory: true)
        let reason = SeatLoginTests.refusal {
            try SeatLoginTests.signIn("work", seats: [SeatLoginTests.seat("work", profile: profile)], scratch: scratch,
                                      code: "c", said: SeatLoginTests.Said())
        }
        #expect(reason?.contains("default login") == true, "accepted: \(reason ?? "signed in")")
        #expect(!scratch.ran, "claude ran with ~/.claude as its profile")
        let signedDefault = FileManager.default.fileExists(
            atPath: scratch.home.appendingPathComponent(".claude/.signed-in").path)
        #expect(!signedDefault, "the sign-in landed in ~/.claude")
    }

    @Test("Sol proof, criterion 3: another seat's profile through a symlinked parent is refused on a fresh machine") func anotherSeatsProfileThroughASymlinkedParentIsRefused() throws {
        let scratch = try SeatLoginTests.scratch(.accepts("c"))
        defer { scratch.remove() }
        // The profile root exists and has a second name; neither profile exists yet.
        let root = scratch.home.appendingPathComponent("profiles", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let alias = scratch.home.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        let seats = [SeatLoginTests.seat("personal", profile: scratch.profile("personal")),
                     SeatLoginTests.seat("work", profile: alias.appendingPathComponent("personal", isDirectory: true))]
        let reason = SeatLoginTests.refusal {
            try SeatLoginTests.signIn("work", seats: seats, scratch: scratch, code: "c", said: SeatLoginTests.Said())
        }
        #expect(reason?.contains("same profile as personal") == true, "accepted: \(reason ?? "signed in")")
        #expect(!scratch.ran, "work's claude ran")
        // What work signed in is personal's profile: personal's next child reads work's login.
        let crossed = FileManager.default.fileExists(
            atPath: scratch.profile("personal").appendingPathComponent(".signed-in").path)
        #expect(!crossed, "work's login landed in personal's profile")
    }
}
