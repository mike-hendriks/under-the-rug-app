import Foundation
import simd

/// One file or folder that lives under the rug.
struct StashedItem: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var originalPath: String
    var stashedPath: String
    /// Position under the rug as a fraction of the rug size, -0.5...0.5 on both axes.
    var x: Float
    var y: Float
    var date: Date
    /// The rug it lies under. Missing in stashes from before there could be more than one rug.
    var rugID: UUID?
}

enum StashError: LocalizedError {
    case cannotStash(String)
    case missing

    var errorDescription: String? {
        switch self {
        case .cannotStash(let name): return "“\(name)” can't go under the rug."
        case .missing: return "That item is no longer under the rug."
        }
    }
}

/// Moves files under the rug (a folder in Application Support) and back out again, and remembers
/// where each one came from. Files are only ever moved, never deleted.
final class Stash {
    struct ShoveResult {
        var added: [StashedItem] = []
        var failures: [(url: URL, error: Error)] = []
    }

    private(set) var items: [StashedItem] = []
    let root: URL
    var stashFolder: URL { root.appendingPathComponent("Stash", isDirectory: true) }
    private var manifest: URL { root.appendingPathComponent("stash.json") }
    private let fm = FileManager.default

    init() {
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = support.appendingPathComponent("Under the Rug", isDirectory: true)
    }

    func load() {
        try? fm.createDirectory(at: stashFolder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: manifest),
           let decoded = try? JSONDecoder().decode([StashedItem].self, from: data) {
            items = decoded
        }
        pruneMissing()
    }

    /// Forgets items whose file was taken out some other way (Finder, Terminal). Returns true if any were.
    @discardableResult
    func pruneMissing() -> Bool {
        let before = items.count
        items.removeAll { !exists($0.stashedPath) }
        guard items.count != before else { return false }
        save()
        removeEmptyFolders()
        return true
    }

    /// Gives items without a (known) rug to `rugID`, e.g. after a rug was removed or on upgrade.
    func adoptOrphans(knownRugs: Set<UUID>, into rugID: UUID) {
        var changed = false
        for i in items.indices where items[i].rugID.map({ !knownRugs.contains($0) }) ?? true {
            items[i].rugID = rugID
            changed = true
        }
        if changed { save() }
    }

    /// Moves `urls` under the rug `rugID`, the n-th one at `positions[n]` (or the last position).
    func shove(_ urls: [URL], positions: [SIMD2<Float>], rugID: UUID) -> ShoveResult {
        var result = ShoveResult()
        try? fm.createDirectory(at: stashFolder, withIntermediateDirectories: true)
        let rootPath = root.standardizedFileURL.path
        for (i, url) in urls.enumerated() {
            let pos = Stash.clampToBody(positions.isEmpty ? .zero : positions[min(i, positions.count - 1)])
            let source = url.standardizedFileURL
            // Something that is already under the rug only moves to a new spot.
            if let existing = items.firstIndex(where: { URL(fileURLWithPath: $0.stashedPath).standardizedFileURL.path == source.path }) {
                items[existing].x = pos.x
                items[existing].y = pos.y
                items[existing].rugID = rugID
                continue
            }
            if source.path.hasPrefix(rootPath) || rootPath.hasPrefix(source.path + "/") || source.path == "/" {
                result.failures.append((url, StashError.cannotStash(source.lastPathComponent)))
                continue
            }
            let id = UUID()
            let folder = stashFolder.appendingPathComponent(id.uuidString, isDirectory: true)
            let target = folder.appendingPathComponent(source.lastPathComponent)
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                try fm.moveItem(at: source, to: target)
                let item = StashedItem(id: id, name: fm.displayName(atPath: target.path), originalPath: source.path,
                                       stashedPath: target.path, x: pos.x, y: pos.y, date: Date(), rugID: rugID)
                items.append(item)
                result.added.append(item)
            } catch {
                try? fm.removeItem(at: folder)
                result.failures.append((url, error))
            }
        }
        save()
        return result
    }

    func move(_ id: UUID, to position: SIMD2<Float>, rugID: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let p = Stash.clampToBody(position)
        items[i].x = p.x
        items[i].y = p.y
        items[i].rugID = rugID
        save()
    }

    /// Puts an item back where it came from (or on the Desktop if that folder is gone). Returns the new location.
    @discardableResult
    func pullOut(_ id: UUID) throws -> URL {
        guard let index = items.firstIndex(where: { $0.id == id }) else { throw StashError.missing }
        let item = items[index]
        let stashed = URL(fileURLWithPath: item.stashedPath)
        var folder = URL(fileURLWithPath: item.originalPath).deletingLastPathComponent()
        var isDir: ObjCBool = false
        if !fm.fileExists(atPath: folder.path, isDirectory: &isDir) || !isDir.boolValue {
            folder = fm.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        }
        let destination = uniqueDestination(in: folder, name: stashed.lastPathComponent)
        try fm.moveItem(at: stashed, to: destination)
        items.remove(at: index)
        save()
        removeEmptyFolders()
        return destination
    }

    /// Puts back everything, or everything under one rug.
    func pullOutAll(rugID: UUID? = nil) -> [Error] {
        var errors: [Error] = []
        for item in items where rugID == nil || item.rugID == rugID {
            do { try pullOut(item.id) } catch { errors.append(error) }
        }
        return errors
    }

    private func uniqueDestination(in folder: URL, name: String) -> URL {
        var candidate = folder.appendingPathComponent(name)
        guard exists(candidate.path) else { return candidate }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var n = 2
        repeat {
            let next = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            candidate = folder.appendingPathComponent(next)
            n += 1
        } while exists(candidate.path)
        return candidate
    }

    /// Also true for broken symlinks, which fileExists(atPath:) would report as missing.
    private func exists(_ path: String) -> Bool {
        (try? fm.attributesOfItem(atPath: path)) != nil
    }

    private func removeEmptyFolders() {
        guard let folders = try? fm.contentsOfDirectory(at: stashFolder, includingPropertiesForKeys: nil) else { return }
        for folder in folders {
            let contents = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? ["?"]
            if contents.filter({ $0 != ".DS_Store" }).isEmpty {
                try? fm.removeItem(at: folder)
            }
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(items) else { return }
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        try? data.write(to: manifest, options: .atomic)
    }

    // MARK: - Placement

    /// Keeps a position on the knotted body, away from the fringe and the edges.
    static func clampToBody(_ p: SIMD2<Float>) -> SIMD2<Float> {
        let fx = 0.5 - Float(RugPattern.fringeFraction) - 0.08
        return SIMD2(min(max(p.x, -fx), fx), min(max(p.y, -0.36), 0.36))
    }

    /// Spreads `count` drops around `center` in a sunflower spiral, about 34 points apart.
    static func spiral(count: Int, around center: SIMD2<Float>, rugSize: SIMD2<Float>) -> [SIMD2<Float>] {
        (0..<count).map { i in
            let r = 34 * sqrt(Float(i))
            let a = Float(i) * 2.399_963
            return clampToBody(center + SIMD2(cos(a) * r / rugSize.x, sin(a) * r / rugSize.y))
        }
    }

    /// Evenly scattered positions over the whole rug (an R2 low-discrepancy sequence).
    static func scatter(count: Int, offset: Int) -> [SIMD2<Float>] {
        let fx = 0.5 - Float(RugPattern.fringeFraction) - 0.08
        return (0..<count).map { k in
            let i = Float(k + offset)
            let u = (0.5 + i * 0.754_877_7).truncatingRemainder(dividingBy: 1)
            let v = (0.5 + i * 0.569_840_3).truncatingRemainder(dividingBy: 1)
            return SIMD2((u * 2 - 1) * fx, (v * 2 - 1) * 0.36)
        }
    }
}
