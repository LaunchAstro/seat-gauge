import Foundation

public enum SeatLogin {
    public struct Request: Equatable, Sendable {
        public let seat: String
        public let email: String?
        public let seatsFile: String?
        public init(seat: String, email: String?, seatsFile: String?) {
            self.seat = seat
            self.email = email
            self.seatsFile = seatsFile
        }
        public init(arguments: [String]) throws { throw ProcessFailure("not built") }
    }

    public struct SignedIn: Equatable, Sendable {
        public let email: String?
        public let plan: String?
        public init(email: String?, plan: String?) {
            self.email = email
            self.plan = plan
        }
    }

    public static func signIn(_ name: String, email: String?, seats: [Seat], home: URL,
                              parent: [String: String], timeout: Duration,
                              code: @escaping @Sendable () -> String?,
                              say: @escaping @Sendable (String) -> Void) throws -> SignedIn {
        throw ProcessFailure("not built")
    }
}
