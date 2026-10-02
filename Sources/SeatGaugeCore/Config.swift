import Foundation

/// The seat list from `seats.json`, and how often to poll it.
public struct Config: Equatable, Sendable {
    public let seats: [Seat]
    public let pollMinutes: Int
}

/// Something wrong with the config file, in one sentence the title bar can
/// show: the decoder's own words, with the line and column it reported.
public struct ConfigProblem: Error, Equatable, Sendable, CustomStringConvertible {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
    public var description: String { reason }
}

/// Reads `seats.json`, and writes the default one when it is not there yet.
/// What was last read, and when, belongs to `ConfigWatcher` instead.
public struct ConfigLoader: Sendable {
    public let file: URL
    public let machine: SeatDiscovery
    public init(file: URL = ConfigLoader.defaultFile, machine: SeatDiscovery = SeatDiscovery()) {
        self.file = file
        self.machine = machine
    }

    public static var defaultFile: URL { AppPaths.support.appendingPathComponent("seats.json") }

    /// What first launch writes when it finds no seat at all. JSON5, so the
    /// comments stay in the file.
    public static let template = seeded(with: [])

    /// The file first launch writes for the seats it found: the four steps
    /// of the first run in the comments, then one line per seat. Only a
    /// path needs quoting, since a found id is plain by construction.
    public static func seeded(with found: [SeatDiscovery.Found]) -> String {
        let root = "~/" + SeatDiscovery.profileFolder
        let lines = found.map { seat -> String in
            let label = seat.id.prefix(1).uppercased() + seat.id.dropFirst()
            switch seat.kind {
            case let .claude(profile):
                return #"    { "id": "\#(seat.id)", "label": "\#(label)", "kind": "claude", "profile": \#(quoted(profile.path)), "login": "own" },"#
            case .codex:
                return #"    { "id": "\#(seat.id)", "label": "\#(label)", "kind": "codex" },"#
            }
        }
        let none = found.isEmpty ? ["  // No seat was found on this Mac, so the list below is empty. Add one as above."] : []
        return ([
            "{",
            "  // Seat Gauge seats, one card each, in the order listed. Save this file and the panel",
            "  // re-reads it within a minute. A seat that cannot be read stays listed and hidden.",
            "  //",
            "  // A seat reaches its card in four steps:",
            "  // 1. Install Seat Gauge.",
            "  // 2. First launch wrote this list from what is on this Mac: a signed-in Codex, and each",
            "  //    Claude profile folder in \(root). With no Claude profile there, it named one",
            "  //    new seat, \"\(SeatDiscovery.freshSeat)\", with its own profile at \(root)/\(SeatDiscovery.freshSeat). Nothing was",
            "  //    read from a login to do it. A folder whose name is not a plain id (a lowercase letter",
            "  //    or digit, then those, - or _), or is \"default\" or \"codex\", was left out: add it by hand.",
            "  // 3. Sign in each Claude seat that is new. Until then its card says it is not logged in.",
            "  //    In Terminal, run this with the seat's own profile, then type /login:",
            "  //      env -u CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR=\"$HOME/.seat-gauge/profiles/\(SeatDiscovery.freshSeat)\" claude",
            "  //    A Codex seat signs in with the codex CLI itself and needs nothing more here.",
            "  // 4. The cards read on the next poll, every \"pollMinutes\" minutes.",
            "  //",
            "  // To add a Claude seat, make it a folder in \(root) named its id, add a line such as",
            #"  // { "id": "work", "label": "Work", "kind": "claude", "profile": "~/.seat-gauge/profiles/work", "login": "own" },"#,
            "  // and sign it in as in step 3. To add Codex once the codex CLI is signed in:",
            #"  // { "id": "codex", "label": "Codex", "kind": "codex" },"#,
            "  //",
            #"  // "id"      lowercase, unique. A claude seat cannot be "default" or "codex", which spend"#,
            "  //           history keeps. \"label\" is what the card shows.",
            #"  // "kind"    "claude" or "codex"."#,
            #"  // "profile" a claude seat's own folder, any path. Required, and never ~/.claude or another"#,
            "  //           seat's, so no card reads a login that is not its own. Spend history reads the",
            "  //           transcripts in it.",
            #"  // "login"   "own": the seat signs in from its own profile, and reads 5h, 7d, fable and its"#,
            #"  //           exact plan. A seat can sign in with an OAuth token instead: leave "login" out"#,
            #"  //           and give "token" the path of a file holding it. A token seat shows 5h and 7d"#,
            "  //           only: no token reports fable or the exact plan.",
            #"  // "account" optional display text, such as "Work"."#,
            #"  // "plan"    optional, such as "Max 20x". A card's plan comes from three places, in this"#,
            #"  //           order: the tier in the seat's own login file, then this "plan", then the plan"#,
            #"  //           the usage reply names, which for Claude is only "max". With none of the three,"#,
            #"  //           the card shows no plan. It never guesses "free"."#,
            #"  // A "codex" seat reads whichever login the codex CLI has, and ignores "profile" and "token"."#,
        ] + none + [
            #"  "seats": ["#,
        ] + lines + [
            "  ],",
            #"  "pollMinutes": 5,"#,
            "}",
            "",
        ]).joined(separator: "\n")
    }

    /// A JSON string, escaped, for a path that may hold any character.
    static func quoted(_ text: String) -> String {
        let writer = JSONEncoder()
        writer.outputFormatting = .withoutEscapingSlashes
        return (try? writer.encode(text)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
    }

    /// What first launch would write on this machine now.
    public func seed() -> String { Self.seeded(with: machine.seats()) }

    public var modifiedAt: Date? {
        try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
    }

    /// First launch seeds the file from the machine; an existing file is
    /// never rewritten.
    public func loadOrCreate() throws -> Config {
        if !FileManager.default.fileExists(atPath: file.path) { try create() }
        return try load()
    }

    /// Writes a draft beside the file, then links it in. A link refuses a
    /// name that is taken, a dangling link included, so a file the user or
    /// another launch put there first is kept as it is.
    private func create() throws {
        let found = machine.seats()
        let folder = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Only the fresh seat's profile is not there yet. Make it, private to
        // the user, so step 3 has a folder to sign in to.
        for case let .claude(profile) in found.map(\.kind) where SeatDiscovery.nothing(at: profile) {
            try? FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
        }
        let draft = folder.appendingPathComponent(".\(file.lastPathComponent).\(UUID().uuidString)")
        try Data(Self.seeded(with: found).utf8).write(to: draft)
        defer { try? FileManager.default.removeItem(at: draft) }
        guard link(draft.path, file.path) == 0 || errno == EEXIST else {
            throw ConfigProblem("\(file.lastPathComponent) could not be written: \(String(cString: strerror(errno)))")
        }
    }

    public func load() throws -> Config {
        guard let data = FileManager.default.contents(atPath: file.path)
        else { throw ConfigProblem("\(file.lastPathComponent) could not be read") }
        return try Self.decode(data)
    }

    /// The shape on disk. The rules are checked below, so a bad seat list
    /// reads as one sentence rather than a decoding trace.
    private struct Stored: Decodable {
        struct StoredSeat: Decodable {
            let id, label, kind: String
            let profile, token: String?
            /// "own" for a profile seat that signs in from its own login
            /// rather than a token file. Nothing else is a spelling.
            let login: String?
            /// Display text. A value that is not text at all is read as none
            /// rather than thrown, so one mistyped field does not cost the
            /// seats that are fine.
            let account, plan: String?

            enum Key: String, CodingKey { case id, label, kind, profile, token, login, account, plan }

            init(from decoder: any Decoder) throws {
                let values = try decoder.container(keyedBy: Key.self)
                id = try values.decode(String.self, forKey: .id)
                label = try values.decode(String.self, forKey: .label)
                kind = try values.decode(String.self, forKey: .kind)
                profile = try values.decodeIfPresent(String.self, forKey: .profile)
                token = try values.decodeIfPresent(String.self, forKey: .token)
                login = try values.decodeIfPresent(String.self, forKey: .login)
                account = try? values.decode(String.self, forKey: .account)
                plan = try? values.decode(String.self, forKey: .plan)
            }
        }
        let seats: [StoredSeat]
        let pollMinutes: Int?
    }

    /// `tokenDirectory` is where a seat with no `token` of its own is looked
    /// up, and is a parameter so a case can point it somewhere temporary.
    /// `home` is whose `~/.claude` a profile may not be, a parameter for the
    /// same reason.
    public static func decode(_ data: Data,
                              tokenDirectory: URL = SeatToken.directory,
                              home: URL = URL(fileURLWithPath: NSHomeDirectory())) throws -> Config {
        let reader = JSONDecoder()
        reader.allowsJSON5 = true
        let stored: Stored
        do {
            stored = try reader.decode(Stored.self, from: data)
        } catch {
            throw ConfigProblem("seats.json: \(Self.say(error))")
        }
        var seats: [Seat] = []
        var seen: Set<String> = []
        var profiles: [String: String] = [:]
        let defaults = [home, home.appendingPathComponent(".claude")].map(Self.resolved)
        for seat in stored.seats {
            guard seat.id == seat.id.lowercased(), !seat.id.isEmpty else {
                throw ConfigProblem("seats.json: the id \"\(seat.id)\" is not lowercase.")
            }
            guard seen.insert(seat.id).inserted else {
                throw ConfigProblem("seats.json: the id \"\(seat.id)\" is used twice.")
            }
            switch seat.kind {
            case "claude":
                // A claude seat with no profile would read whatever ~/.claude
                // is signed into, and draw that account under its own name.
                guard let profile = seat.profile else {
                    throw ConfigProblem("seats.json: the claude seat \"\(seat.id)\" has no profile, so it would read whichever account ~/.claude is signed into; give it a profile and \"login\": \"own\".")
                }
                let directory = URL(fileURLWithPath: NSString(string: profile).expandingTildeInPath, isDirectory: true)
                guard !defaults.contains(Self.resolved(directory)) else {
                    throw ConfigProblem("seats.json: the claude seat \"\(seat.id)\" has the default login's directory as its profile, so it would read whichever account ~/.claude is signed into; give it a directory of its own.")
                }
                if let other = profiles.updateValue(seat.id, forKey: Self.resolved(directory)) {
                    throw ConfigProblem("seats.json: \"\(seat.id)\" has the same profile as \"\(other)\", so both cards would read one login; give each seat a directory of its own.")
                }
                // Spend history files a seat under its id, and keeps these two
                // names for the default login and for Codex.
                guard ![SpendAttribution.mainDirectory, CodexRollout.seat].contains(seat.id) else {
                    throw ConfigProblem("seats.json: a claude seat cannot have the id \"\(seat.id)\", which spend history keeps for \(seat.id == CodexRollout.seat ? "Codex" : "the default login").")
                }
                let id = SeatID(rawValue: seat.id)
                // A seat that owns its login pins no token, even when a file
                // is lying in the token directory under its name. Any
                // other spelling is refused rather than read as a token seat.
                let own = seat.login == "own"
                guard seat.login == nil || own else {
                    throw ConfigProblem("seats.json: \"\(seat.id)\" has login \"\(seat.login ?? "")\", and the only login a seat can say is \"own\".")
                }
                guard !own || seat.token == nil else {
                    throw ConfigProblem("seats.json: \"\(seat.id)\" says \"login\": \"own\" and names a \"token\" too. A seat signs in one way.")
                }
                // A named source is taken as given, so a path that is not there
                // is an unreadable seat with a reason rather than a silent
                // fall back to somebody else's token.
                let token = own ? nil : seat.token.map {
                    URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath)
                } ?? SeatToken.defaultSource(for: id, in: tokenDirectory)
                seats.append(Seat(id: id, label: seat.label,
                                  kind: .claude(profileDir: directory), tokenFile: token,
                                  account: seat.account, plan: seat.plan))
            case "codex":
                // Codex signs in from its own config, so it ignores both
                // "profile" and "token" the same way.
                seats.append(Seat(id: SeatID(rawValue: seat.id), label: seat.label, kind: .codex,
                                  account: seat.account, plan: seat.plan))
            default:
                throw ConfigProblem("seats.json: \"\(seat.id)\" has kind \"\(seat.kind)\", which is neither claude nor codex.")
            }
        }
        return Config(seats: seats, pollMinutes: max(1, stored.pollMinutes ?? 5))
    }

    /// A directory as the file system finds it, so `~/.claude/`, a symlink
    /// to it and `~/./.claude` are one place.
    static func resolved(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// The decoder's own words: for a malformed file they carry the line and
    /// the column, so the title bar shows where to look.
    static func say(_ error: any Error) -> String {
        guard case let DecodingError.dataCorrupted(context) = error,
              let said = (context.underlyingError as NSError?)?
                  .userInfo[NSDebugDescriptionErrorKey] as? String else { return "\(error)" }
        return said
    }
}

/// The last good config and the mtime it was read at. A file that will not
/// parse leaves the config in use where it is and puts the decoder's words in
/// `problem`, so the loop keeps polling.
public actor ConfigWatcher {
    public private(set) var config: Config
    public private(set) var problem: String?
    private let loader: ConfigLoader
    private var readAt: Date?

    /// Fails closed at launch too: a `seats.json` that will not parse before
    /// anything good has been read is reported with the decoder's line and
    /// column, and the seats first launch would seed on this machine stand
    /// in, so `watch` keeps polling instead of ending on the first read.
    public init(loader: ConfigLoader = ConfigLoader()) throws {
        self.loader = loader
        do {
            config = try loader.loadOrCreate()
        } catch {
            problem = (error as? ConfigProblem)?.reason ?? "\(error)"
            config = (try? ConfigLoader.decode(Data(loader.seed().utf8)))
                ?? Config(seats: [], pollMinutes: 5)
        }
        readAt = loader.modifiedAt
    }

    /// True when the file had changed and the new seat list is now in use.
    @discardableResult
    public func refresh() -> Bool {
        let changed = loader.modifiedAt
        guard changed != readAt else { return false }
        readAt = changed
        do {
            config = try loader.load()
            problem = nil
            return true
        } catch {
            problem = (error as? ConfigProblem)?.reason ?? "\(error)"
            return false
        }
    }
}
