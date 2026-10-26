import Foundation
import Testing
import SeatGaugeCore

@Suite struct SolPR73FixProofTests {
    @Test("Sol proof, criterion correctness: a configured email-flag seat survives the CLI hand-off")
    func aConfiguredEmailFlagSeatSurvivesTheCLIHandOff() throws {
        let scratch = try SeatLoginTests.scratch(.accepts("fake-code"))
        defer { scratch.remove() }
        let id = "--email"
        let bytes = try JSONSerialization.data(withJSONObject: ["seats": [[
            "id": id, "label": "Work", "kind": "claude",
            "profile": scratch.profile("work").path, "login": "own"
        ]]])
        // seats.json now refuses an id that is not a plain id, so this one
        // comes from a seat list built another way, which sign-in still serves.
        #expect(throws: ConfigProblem.self) { try ConfigLoader.decode(bytes, home: scratch.home) }
        let seats = [SeatLoginTests.seat(id, profile: scratch.profile("work"))]
        let signed = try SeatLoginTests.signIn(id, seats: seats, scratch: scratch,
                                               code: "fake-code", said: SeatLoginTests.Said())
        #expect(signed.plan == "pro")
        let file = scratch.home.appendingPathComponent("seats.json").path
        let request = try SeatLogin.Request(arguments: [id, file])
        #expect(request == .init(seat: id, email: nil, seatsFile: file))
    }
}
