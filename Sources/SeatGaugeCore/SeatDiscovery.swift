import Foundation

/// The seats already on this Mac, for first launch to seed `seats.json` with.
///
/// Everything is found by name and existence. No login, token or file inside
/// a profile is opened, so nothing a seat signs in with is read to seed it.
public struct SeatDiscovery: Sendable {
    public let home: URL
    public let codexLogin: URL

    public init(home: URL = URL(fileURLWithPath: NSHomeDirectory()),
                codexLogin: URL = CodexPlanFile.defaultFile) {
        self.home = home
        self.codexLogin = codexLogin
    }

    /// One seat found, as `seats.json` will name it.
    public struct Found: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case claude(profile: URL)
            case codex
        }
        public let id: String
        public let kind: Kind
        public init(id: String, kind: Kind) {
            self.id = id
            self.kind = kind
        }
    }

    /// Where the app keeps Claude seat profiles, under the home. One folder,
    /// the same on every Mac, so first launch needs to know nobody's naming.
    public static let profileFolder = ".seat-gauge/profiles"
    /// The seat first launch names when no Claude profile is found.
    public static let freshSeat = "claude"
    public var profileRoot: URL { home.appendingPathComponent(Self.profileFolder, isDirectory: true) }

    /// Every profile folder under the root, by id, then Codex when it is
    /// signed in. With no profile, one fresh Claude seat whose folder is not
    /// there yet. Nothing is listed that `ConfigLoader.decode` would refuse.
    public func seats() -> [Found] {
        let main = Place(home.appendingPathComponent(".claude", isDirectory: true))
        let homePlace = Place(home)
        // A profile at or inside the default login, or the home itself, would
        // read whatever `~/.claude` is signed into.
        func refused(_ url: URL) -> Bool {
            Place(url) == homePlace || main.map { Place.chain(url).contains($0) } == true
        }
        var claude: [Found] = []
        let root = profileRoot
        if !refused(root) {
            claude = profiles(in: root, refusing: refused)
            let fresh = root.appendingPathComponent(Self.freshSeat, isDirectory: true)
            if claude.isEmpty, Self.nothing(at: fresh), Self.folderOrNothing(at: root) {
                claude = [Found(id: Self.freshSeat, kind: .claude(profile: fresh))]
            }
        }
        var isFolder: ObjCBool = false
        let codex = FileManager.default.fileExists(atPath: codexLogin.path, isDirectory: &isFolder) && !isFolder.boolValue
        return claude + (codex ? [Found(id: CodexRollout.seat, kind: .codex)] : [])
    }

    private func profiles(in root: URL, refusing refused: (URL) -> Bool) -> [Found] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        // Real folders first, then links, each by name: of two names for one
        // folder, the folder's own is kept.
        let candidates = names.filter(Self.isID).sorted().map { name in
            (name, root.appendingPathComponent(name, isDirectory: true))
        }.filter { name, url in
            var isFolder: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) && isFolder.boolValue
                && !refused(url)
        }.sorted { Self.isLink($0.1) == Self.isLink($1.1) ? $0.0 < $1.0 : !Self.isLink($0.1) }
        var taken: Set<Place> = []
        let kept = candidates.filter { _, url in Place(url).map { taken.insert($0).inserted } ?? false }
        return kept.map(\.0).sorted().map { Found(id: $0, kind: .claude(profile: root.appendingPathComponent($0, isDirectory: true))) }
    }

    /// Lowercase letters, digits, `-` and `_`, starting with a letter or
    /// digit, and not a name spend history keeps. Anything else is left for
    /// the user to add by hand, so an odd name never reaches the file.
    static func isID(_ name: String) -> Bool {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_")
        guard let first = name.first, first.isASCII, first.isLetter || first.isNumber,
              name.allSatisfy(allowed.contains) else { return false }
        return ![SpendAttribution.mainDirectory, CodexRollout.seat].contains(name)
    }

    static func isLink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    /// No file, folder or link at all, a dangling link included.
    static func nothing(at url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) != 0 && errno == ENOENT
    }

    static func folderOrNothing(at url: URL) -> Bool {
        var isFolder: ObjCBool = false
        return !FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) && nothing(at: url)
            || isFolder.boolValue
    }
}

/// A folder as the disk knows it: its device and inode. A link, `..` and the
/// data volume's own path for a folder all name one `Place`, where comparing
/// paths would tell them apart.
struct Place: Hashable {
    let device: dev_t
    let inode: ino_t

    init?(_ url: URL) {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        device = info.st_dev
        inode = info.st_ino
    }

    /// The place a path lands on and every folder above it.
    static func chain(_ url: URL) -> [Place] {
        var at = url.resolvingSymlinksInPath().standardizedFileURL
        var places: [Place] = []
        while true {
            if let place = Place(at) { places.append(place) }
            let up = at.deletingLastPathComponent().standardizedFileURL
            guard up.path != at.path else { return places }
            at = up
        }
    }
}
