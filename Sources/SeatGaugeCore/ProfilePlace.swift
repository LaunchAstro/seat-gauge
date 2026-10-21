import Foundation

/// Where a Claude profile is, or will be once something makes it, compared
/// the one way every check uses: `seats.json`'s, first launch's and Sign in's.
/// Every Claude seat has its own login, so a profile is refused when it is the
/// home itself, `~/.claude` or anything inside it, or another seat's.
///
/// A place is the nearest folder on the path that is there, by device and
/// inode, then the names below that one. Its data-volume path, a link (a
/// dangling one too), `..`, another Unicode form and another case all land on
/// one place, where comparing paths would tell them apart. Names are folded
/// for case on every volume: on a case-sensitive one that refuses two
/// spellings that are really two folders, which is the safe way to be wrong.
struct ProfilePlace: Hashable {
    let place: Place
    let below: [String]
    /// The folder `place` is and every folder above it, for "inside". Not
    /// part of what makes two places one.
    let above: [Place]

    static func == (a: ProfilePlace, b: ProfilePlace) -> Bool { a.place == b.place && a.below == b.below }
    func hash(into hasher: inout Hasher) { hasher.combine(place); hasher.combine(below) }

    /// At `other` or inside it.
    func isAtOrInside(_ other: ProfilePlace) -> Bool {
        if place == other.place { return below.starts(with: other.below) }
        // `other` is a folder that is there, above this one's base.
        return other.below.isEmpty && above.contains(other.place)
    }

    /// Both places a profile path can mean. The CLI is handed it as written
    /// and joins names onto it, which undoes a `..` by name; the gauge's own
    /// reads append to it and the file system walks `link/..` from where the
    /// link points. A rule that refuses either one refuses the profile. Nil
    /// when either cannot be followed: links that go round in a loop, or a
    /// `..` out of something that is not a folder.
    static func of(_ url: URL) -> [ProfilePlace]? {
        guard let named = place(url, byName: true), let walked = place(url, byName: false) else { return nil }
        return named == walked ? [named] : [named, walked]
    }

    /// Two profiles that share a place, by any meaning of either.
    static func same(_ a: URL, _ b: URL) -> Bool {
        guard let mine = of(a), let theirs = of(b) else { return false }
        return mine.contains(where: theirs.contains)
    }

    /// True when `url` is the home itself, `~/.claude` or anything inside
    /// `~/.claude`, by any meaning of it, so a seat there would read whatever
    /// the default login is signed into.
    static func isDefaultLogin(_ url: URL, home: URL) -> Bool {
        guard let places = of(url) else { return false }
        let homes = of(home) ?? []
        let mains = of(home.appendingPathComponent(".claude", isDirectory: true)) ?? []
        return places.contains { place in
            homes.contains(place) || mains.contains { place.isAtOrInside($0) }
        }
    }

    static func place(_ url: URL, byName: Bool) -> ProfilePlace? {
        var names: [String] = []
        for name in url.path.split(separator: "/").map(String.init) where !byName || name != "." {
            if byName, name == ".." { _ = names.popLast() } else { names.append(name) }
        }
        for _ in 0..<64 {
            // The longest stretch from the root that is there. The file
            // system walks it, so a link or `..` in it lands where it goes.
            var there = 0
            while there < names.count, Place(URL(fileURLWithPath: "/" + names[...there].joined(separator: "/"))) != nil {
                there += 1
            }
            let base = "/" + names[..<there].joined(separator: "/")
            guard let place = Place(URL(fileURLWithPath: base)) else { return nil }
            let after = names[there...]
            // A dangling link is made where it points, so follow it.
            if let next = after.first,
               let target = try? FileManager.default.destinationOfSymbolicLink(atPath: base + "/" + next) {
                names = (target.hasPrefix("/") ? [] : Array(names[..<there]))
                    + target.split(separator: "/").map(String.init) + after.dropFirst()
                continue
            }
            // Nothing past the base is there, so nothing past it is a link,
            // and `..` undoes the name before it. Once undone, what is left
            // may be there after all, so look again. A `..` that climbs above
            // the base goes back to the file system.
            if after.contains(where: { $0 == "." || $0 == ".." }) {
                var below: [String] = []
                for (index, name) in zip(after.indices, after) where name != "." {
                    if name != ".." {
                        below.append(name)
                    } else if below.popLast() == nil {
                        below = [".."] + names[(index + 1)...]
                        break
                    }
                }
                names = Array(names[..<there]) + below
                continue
            }
            // A Swift string already equals its other Unicode forms.
            return ProfilePlace(place: place, below: after.map { $0.folding(options: .caseInsensitive, locale: nil) },
                                above: Place.chain(base))
        }
        return nil
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

    /// The folder at `path`, which is there, and every folder above it, by
    /// the file system's own resolution of its links and `..`.
    static func chain(_ path: String) -> [Place] {
        guard let real = realpath(path, nil) else { return [] }
        defer { free(real) }
        var at = URL(fileURLWithPath: String(cString: real))
        var places: [Place] = []
        while true {
            if let place = Place(at) { places.append(place) }
            let up = at.deletingLastPathComponent()
            guard up.path != at.path else { return places }
            at = up
        }
    }
}
