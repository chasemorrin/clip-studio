import Foundation

/// How much space Clip Studio takes on this iPhone, and clearing the temporary video files.
enum StorageUsage {
    struct Report {
        var total: Int64
        var saved: Int64      // saved footage: clips, analysis and thumbnails
        var temporary: Int64  // copies of videos picked from Photos, and exported clips
        var other: Int64      // the app's settings, caches and other files
    }

    private static var home: URL { URL(fileURLWithPath: NSHomeDirectory()) }
    private static var temp: URL { FileManager.default.temporaryDirectory }
    private static var projects: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Projects")
    }

    /// Adds up file sizes (slow for big folders, so call it off the main thread).
    static func measure() -> Report {
        let total = size(of: home)
        let tmp = size(of: temp)
        let saved = size(of: projects)
        return Report(total: total, saved: saved, temporary: tmp, other: max(0, total - tmp - saved))
    }

    /// Deletes the temporary copies. Saved footage reopens from Photos, and exported clips are made again when needed.
    static func clearTemporary() {
        let fm = FileManager.default
        for url in (try? fm.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: url)
        }
    }

    private static func size(of folder: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return 0 }
        var sum: Int64 = 0
        for case let url as URL in walker {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            sum += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        return sum
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
