// Skipper – ein Windows-artiger Datei-Explorer für macOS (zwei Bereiche, Tastatur, Ordner-Cockpit)
// Einzelne Datei, AppKit, keine Abhängigkeiten. Build: ./build.sh

import Cocoa
import Quartz
import Carbon.HIToolbox

/// Übersetzter Text. Schlüssel ist der englische Text, Übersetzungen liegen in Resources/<Sprache>.lproj
/// (Mehrzahlformen in Localizable.stringsdict). Mit Argumenten dient der Text als Formatstring.
func L(_ key: String, _ args: CVarArg...) -> String {
    let s = NSLocalizedString(key, comment: "")
    return args.isEmpty ? s : String(format: s, locale: .current, arguments: args)
}

// MARK: - Model

final class FileItem {
    let url: URL
    let name: String
    let isDirectory: Bool      // inkl. Pakete (.app)
    let isFolder: Bool         // navigierbarer Ordner (kein Paket)
    let size: Int64
    let modified: Date
    let kind: String
    let hidden: Bool

    static let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .totalFileSizeKey,
                                         .contentModificationDateKey, .localizedTypeDescriptionKey, .isHiddenKey]
    static let keySet = Set(keys)

    init(url: URL) {
        self.url = url
        let v = try? url.resourceValues(forKeys: FileItem.keySet)
        isDirectory = v?.isDirectory ?? false
        isFolder = isDirectory && !(v?.isPackage ?? false)
        name = url.lastPathComponent
        size = Int64(v?.totalFileSize ?? v?.fileSize ?? 0)
        modified = v?.contentModificationDate ?? .distantPast
        kind = v?.localizedTypeDescription ?? (isDirectory ? L("Folder") : L("File"))
        hidden = (v?.isHidden ?? false) || name.hasPrefix(".")
    }
}

let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .short
    f.timeStyle = .short
    return f
}()

let sizeFormatter: ByteCountFormatter = {
    let f = ByteCountFormatter()
    f.countStyle = .file
    return f
}()

enum Icons {
    private static var cache: [String: NSImage] = [:]
    static func icon(for item: FileItem) -> NSImage {
        let ext = item.url.pathExtension.lowercased()
        let cacheable = !item.isDirectory && !ext.isEmpty
        if cacheable, let c = cache[ext] { return c }
        let img = NSWorkspace.shared.icon(forFile: item.url.path)
        img.size = NSSize(width: 16, height: 16)
        if cacheable { cache[ext] = img }
        return img
    }
}

extension Notification.Name {
    static let fileClipboardChanged = Notification.Name("ExplorerFileClipboardChanged")
    static let pinnedChanged = Notification.Name("ExplorerPinnedChanged")
}

// MARK: - Zwischenablage (Kopieren / Ausschneiden)

enum FileClipboard {
    static var cutURLs: [URL] = []
    static var changeCount = -1

    static var isCutActive: Bool {
        !cutURLs.isEmpty && NSPasteboard.general.changeCount == changeCount
    }

    static func isCut(_ url: URL) -> Bool { isCutActive && cutURLs.contains(url) }

    static func write(_ urls: [URL], cut: Bool) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls.map { $0 as NSURL })
        cutURLs = cut ? urls : []
        changeCount = pb.changeCount
        NotificationCenter.default.post(name: .fileClipboardChanged, object: nil)
    }

    static func clearCut() {
        cutURLs = []
        NotificationCenter.default.post(name: .fileClipboardChanged, object: nil)
    }

    static func read() -> [URL] {
        let objs = NSPasteboard.general.readObjects(forClasses: [NSURL.self],
                                                    options: [.urlReadingFileURLsOnly: true]) ?? []
        return objs.compactMap { ($0 as? NSURL) as URL? }
    }

    static var hasFiles: Bool {
        NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }
}

// MARK: - Dateioperationen

enum ConflictChoice { case replace, keepBoth, skip }

enum FileOps {
    /// Windows-Benennung: "Name - Kopie.txt", "Name - Kopie (2).txt" bzw. "Neuer Ordner (2)"
    static func unique(in dir: URL, name: String, isDir: Bool, copySuffix: Bool) -> URL {
        let fm = FileManager.default
        let first = dir.appendingPathComponent(name)
        if !copySuffix && !fm.fileExists(atPath: first.path) { return first }
        let ns = name as NSString
        let ext = isDir ? "" : ns.pathExtension
        let base = ext.isEmpty ? name : ns.deletingPathExtension
        let dotExt = ext.isEmpty ? "" : "." + ext
        var i = 1
        while true {
            let stem: String
            if copySuffix {
                stem = i == 1 ? L("%@ - Copy", base) : L("%@ - Copy (%ld)", base, i)
            } else {
                stem = "\(base) (\(i + 1))"
            }
            let candidate = dir.appendingPathComponent(stem + dotExt)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            i += 1
        }
    }

    static func isDir(_ url: URL) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
    }

    static func canonical(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func volumeID(_ url: URL) -> NSObject? {
        (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
    }
}

// MARK: - Ordner beobachten (Auto-Aktualisierung)

final class DirWatcher {
    private var source: DispatchSourceFileSystemObject?

    func watch(_ url: URL, onChange: @escaping () -> Void) {
        stop()
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                          eventMask: [.write, .delete, .rename],
                                                          queue: .main)
        s.setEventHandler(handler: onChange)
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    deinit { stop() }
}

// MARK: - Tabelle mit Windows-Tastatur

final class FileTableView: NSTableView {
    weak var explorer: ExplorerController?

    override func keyDown(with e: NSEvent) {
        guard let ex = explorer else { return super.keyDown(with: e) }
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        switch e.keyCode {
        case 53:                                       // Escape → Volltextsuche beenden
            if mods.isEmpty, ex.isDeepSearch { ex.endDeepSearch(); return }
        case 48:                                       // Tab → anderer Bereich
            if mods.isEmpty || mods == [.shift], ex.focusOtherPane() { return }
        case 36, 76:                                   // Return / Enter → öffnen
            if mods.isEmpty { ex.openSelection(); return }
        case 51:                                       // Backspace
            if mods == [.command] { ex.trashSelection(); return }
            if mods.isEmpty { ex.goBack(); return }
        case 117:                                      // Entf (fn+Backspace)
            if mods == [.shift] { ex.deletePermanently(nil) } else { ex.trashSelection() }
            return
        case 120:                                      // F2 → umbenennen
            ex.beginRename(); return
        case 96:                                       // F5 → aktualisieren
            ex.reload(); return
        case 49:                                       // Leertaste → Quick Look
            if mods.isEmpty { ex.togglePreview(); return }
        case 126:                                      // ↑
            if mods == [.option] { ex.goUp(); return }
        case 123:                                      // ←
            if mods == [.option] { ex.goBack(); return }
        case 124:                                      // →
            if mods == [.option] { ex.goForward(); return }
        default:
            break
        }
        super.keyDown(with: e)
    }
}

// MARK: - Zoom (⌘+ / ⌘− / ⌘0 wie in VS Code)

extension Notification.Name {
    static let zoomChanged = Notification.Name("ExplorerZoomChanged")
}

enum Zoom {
    static let steps: [CGFloat] = [0.5, 0.6, 0.7, 0.8, 0.9, 1.0, 1.1, 1.25, 1.4, 1.6, 1.8, 2.0, 2.4, 3.0]

    static var factor: CGFloat {
        let v = UserDefaults.standard.double(forKey: "zoomFactor")
        return v > 0 ? CGFloat(v) : 1
    }

    static func set(_ f: CGFloat) {
        let old = factor
        let clamped = min(max(f, steps.first!), steps.last!)
        guard abs(clamped - old) > 0.001 else { NSSound.beep(); return }
        UserDefaults.standard.set(Double(clamped), forKey: "zoomFactor")
        NotificationCenter.default.post(name: .zoomChanged, object: nil, userInfo: ["old": old])
    }

    static func zoomIn() { set(steps.first { $0 > factor + 0.001 } ?? steps.last!) }
    static func zoomOut() { set(steps.last { $0 < factor - 0.001 } ?? steps.first!) }
    static func reset() { set(1) }

    /// Wert × Zoomfaktor (für Schriftgrößen, Zeilenhöhen, Symbole).
    static func s(_ v: CGFloat) -> CGFloat { (v * factor).rounded() }
    /// Zellen-Kennung je Zoomstufe, damit wiederverwendete Zellen die passende Größe haben.
    static var suffix: String { "@\(Int((factor * 100).rounded()))" }
}

// MARK: - Ordnergrößen (im Hintergrund, mit Zwischenspeicher)

struct FolderStats {
    let files: Int
    let bytes: Int64
    let partial: Bool      // einige Unterordner waren nicht lesbar → Mindestwert
    var catBytes: [Int64] = Array(repeating: 0, count: FileCategory.allCases.count)
    var catCounts: [Int] = Array(repeating: 0, count: FileCategory.allCases.count)
}

/// Grobe Dateikategorien für die Ordner-Übersicht (Cockpit) in der Statuszeile.
enum FileCategory: Int, CaseIterable {
    case audio, video, images, documents, code, archives, apps, other

    var title: String {
        switch self {
        case .audio: return L("Audio")
        case .video: return L("Video")
        case .images: return L("Pictures")
        case .documents: return L("Documents")
        case .code: return L("Code")
        case .archives: return L("Archives")
        case .apps: return L("Applications")
        case .other: return L("Other")
        }
    }

    var color: NSColor {
        switch self {
        case .audio: return .systemPurple
        case .video: return .systemRed
        case .images: return .systemGreen
        case .documents: return .systemBlue
        case .code: return .systemOrange
        case .archives: return .systemBrown
        case .apps: return .systemTeal
        case .other: return .systemGray
        }
    }

    private static let byExtension: [String: FileCategory] = {
        var m: [String: FileCategory] = [:]
        func add(_ c: FileCategory, _ exts: String) { exts.split(separator: " ").forEach { m[String($0)] = c } }
        add(.audio, "wav aif aiff aifc mp3 m4a aac flac ogg oga opus alac caf mid midi wma ape dsf dff ncw nki nkm nkx exs sfz rx2 rex als logicx band ptx amr m4b m4p")
        add(.video, "mp4 mov m4v avi mkv webm mts m2ts mxf braw r3d wmv flv mpg mpeg 3gp vob prores hevc fcpbundle")
        add(.images, "jpg jpeg png gif heic heif tif tiff bmp webp raw cr2 cr3 nef arw dng orf rw2 raf psd psb svg ico icns xcf afphoto sketch photoslibrary")
        add(.documents, "pdf doc docx xls xlsx ppt pptx pages numbers key txt rtf rtfd md odt ods odp csv epub tex log")
        add(.code, "swift js mjs cjs ts tsx jsx py rb go rs c h cc cpp hpp m mm java kt kts json yaml yml xml html htm css scss sass less sh zsh bash php sql toml lock map vue svelte gradle plist ipynb")
        add(.archives, "zip rar 7z tar gz tgz bz2 xz zst dmg iso pkg cab jar sparseimage sparsebundle")
        add(.apps, "app appex framework dylib kext prefpane")
        return m
    }()

    static func of(extension ext: String) -> FileCategory { byExtension[ext.lowercased()] ?? .other }
    static func of(_ url: URL) -> FileCategory { of(extension: url.pathExtension) }
}

extension Notification.Name {
    static let folderStatsInvalidated = Notification.Name("ExplorerFolderStatsInvalidated")
}

/// Zählt Dateien und Bytes eines Ordners inkl. aller Unterordner. Läuft auf einer Hintergrund-
/// Warteschlange (3 parallel), bleibt auf demselben Laufwerk, merkt sich Ergebnisse.
/// Alle öffentlichen Methoden nur vom Main-Thread aufrufen.
final class FolderSizer {
    static let shared = FolderSizer()

    private final class SizeOp: Operation, @unchecked Sendable {
        let path: String
        var waiters: [(owner: ObjectIdentifier, done: (FolderStats) -> Void)] = []
        var result: FolderStats?
        init(path: String) { self.path = path }
        override func main() {
            result = FolderSizer.compute(path) { [unowned self] in self.isCancelled }
        }
    }

    private var cache: [String: FolderStats] = [:]
    private var pending: [String: SizeOp] = [:]
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 3
        q.qualityOfService = .utility
        return q
    }()

    func stats(_ url: URL) -> FolderStats? { cache[url.standardizedFileURL.path] }

    func request(_ urls: [URL], owner: AnyObject, done: @escaping (String, FolderStats) -> Void) {
        let oid = ObjectIdentifier(owner)
        for u in urls {
            let path = u.standardizedFileURL.path
            if cache[path] != nil { continue }
            if let op = pending[path] {
                if !op.waiters.contains(where: { $0.owner == oid }) { op.waiters.append((oid, { done(path, $0) })) }
                continue
            }
            let op = SizeOp(path: path)
            op.waiters = [(oid, { done(path, $0) })]
            op.completionBlock = { [weak self, weak op] in
                guard let op = op else { return }
                DispatchQueue.main.async {
                    guard let self = self, self.pending[op.path] === op else { return }
                    self.pending[op.path] = nil
                    guard !op.isCancelled, let r = op.result else { return }
                    self.cache[op.path] = r
                    op.waiters.forEach { $0.done(r) }
                }
            }
            pending[path] = op
            queue.addOperation(op)
        }
    }

    /// Alle Aufträge dieses Bereichs abbrechen (z. B. beim Ordnerwechsel).
    func cancel(owner: AnyObject) {
        let oid = ObjectIdentifier(owner)
        for (path, op) in pending {
            op.waiters.removeAll { $0.owner == oid }
            if op.waiters.isEmpty { op.cancel(); pending[path] = nil }
        }
    }

    /// Werte verwerfen, die sich durch eine Änderung an `url` geändert haben können
    /// (der Ordner selbst, alle übergeordneten und alle darin liegenden).
    func invalidate(around urls: [URL]) {
        let paths = urls.map { $0.standardizedFileURL.path }
        cache = cache.filter { key, _ in
            !paths.contains { p in key == p || p.hasPrefix(key + "/") || key.hasPrefix(p + "/") }
        }
        NotificationCenter.default.post(name: .folderStatsInvalidated, object: nil)
    }

    /// F5: alles unterhalb dieses Ordners neu berechnen.
    func invalidate(under dir: URL) {
        let root = dir.standardizedFileURL.path
        let prefix = root == "/" ? "/" : root + "/"
        cache = cache.filter { key, _ in !key.hasPrefix(prefix) }
        for (path, op) in pending where path.hasPrefix(prefix) { op.cancel(); pending[path] = nil }
    }

    /// Schneller Durchlauf mit fts (physisch, nicht über Laufwerksgrenzen).
    static func compute(_ path: String, isCancelled: () -> Bool) -> FolderStats? {
        guard let cPath = strdup(path) else { return nil }
        defer { free(cPath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else { return nil }
        defer { fts_close(fts) }
        var files = 0, bytes: Int64 = 0, partial = false, n = 0
        var catBytes = Array(repeating: Int64(0), count: FileCategory.allCases.count)
        var catCounts = Array(repeating: 0, count: FileCategory.allCases.count)
        var bundleLevel: Int16 = -1                    // > -1: wir sind in einem Bundle (.app, .logicx …)
        var bundleCat = FileCategory.other
        /// Dateiendung direkt aus dem C-Pfad lesen (schnell, ohne Pfad-String)
        func ext(_ ent: UnsafeMutablePointer<FTSENT>) -> String? {
            guard let p = ent.pointee.fts_path else { return nil }
            let len = Int(ent.pointee.fts_pathlen)
            var i = len - 1
            while i >= 0 && i >= len - 16 {
                let ch = p[i]
                if ch == 0x2F { return nil }                         // '/'
                if ch == 0x2E {                                      // '.'
                    guard i < len - 1 else { return nil }
                    return String(decoding: UnsafeRawBufferPointer(start: p + i + 1, count: len - i - 1), as: UTF8.self)
                }
                i -= 1
            }
            return nil
        }
        while let ent = fts_read(fts) {
            let level = ent.pointee.fts_level
            switch Int32(ent.pointee.fts_info) {
            case FTS_D:
                if bundleLevel < 0, level > 0, let e = ext(ent) {
                    let c = FileCategory.of(extension: e)
                    if c == .apps || ["logicx", "fcpbundle", "photoslibrary", "band", "rtfd", "sparsebundle"].contains(e.lowercased()) {
                        bundleLevel = level
                        bundleCat = c
                    }
                }
            case FTS_DP:
                if level == bundleLevel { bundleLevel = -1 }
            case FTS_F:
                files += 1
                let size = ent.pointee.fts_statp.map { Int64($0.pointee.st_size) } ?? 0
                bytes += size
                let c = bundleLevel >= 0 ? bundleCat : (ext(ent).map(FileCategory.of(extension:)) ?? .other)
                catBytes[c.rawValue] += size
                catCounts[c.rawValue] += 1
            case FTS_DNR, FTS_ERR, FTS_NS:
                partial = true
            default:
                break
            }
            n += 1
            if n & 1023 == 0, isCancelled() { return nil }
        }
        return FolderStats(files: files, bytes: bytes, partial: partial, catBytes: catBytes, catCounts: catCounts)
    }
}

/// Schmaler, farbiger Balken: Anteile der Kategorien.
final class CategoryBar: NSView {
    var parts: [(NSColor, CGFloat)] = [] { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: Zoom.s(110), height: Zoom.s(8)) }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0, dy: max(0, (bounds.height - Zoom.s(8)) / 2))
        let clip = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        NSColor.quaternaryLabelColor.setFill()
        clip.fill()
        clip.addClip()
        let total = parts.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return }
        var x = r.minX
        for (color, v) in parts where v > 0 {
            let w = r.width * v / total
            color.setFill()
            NSRect(x: x, y: r.minY, width: w + 0.5, height: r.height).fill()
            x += w
        }
    }
}

let countFormatter: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    return f
}()

// MARK: - Favoriten (eigene Datei: ~/Library/Application Support/Skipper/favorites.json)

/// Einfache, von Hand bearbeitbare JSON-Liste. Pro Eintrag Pfad + Lesezeichen von macOS:
/// Existiert der Pfad, gilt der Pfad (so wirken Handänderungen). Fehlt er, wird der Ordner
/// über das Lesezeichen wiedergefunden (umbenannt/verschoben) und der Pfad korrigiert.
final class Favorites {
    static let shared = Favorites()
    static let dragType = NSPasteboard.PasteboardType("com.aioxio.explorer.favorite-index")

    private struct Entry: Codable { var path: String; var bookmark: Data? }
    private struct FileFormat: Codable { var favorites: [Entry] }

    private var entries: [Entry] = []
    private let watcher = DirWatcher()
    let fileURL: URL

    var urls: [URL] { entries.map { URL(fileURLWithPath: $0.path) } }

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Skipper", isDirectory: true)
        // Umzug vom früheren Namen „Explorer“
        let oldDir = base.appendingPathComponent("Explorer", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path),
           FileManager.default.fileExists(atPath: oldDir.appendingPathComponent("favorites.json").path) {
            try? FileManager.default.moveItem(at: oldDir, to: dir)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("favorites.json")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            load()
        } else {
            // Einmalige Übernahme der früher „angehefteten“ Ordner
            let old = UserDefaults.standard.stringArray(forKey: "pinnedFolders") ?? []
            entries = old.map { Entry(path: $0, bookmark: Self.bookmark(URL(fileURLWithPath: $0))) }
            save()
        }
        // Änderungen von außen (Datei von Hand bearbeitet) sofort übernehmen
        watcher.watch(dir) { [weak self] in self?.reloadIfChanged() }
    }

    private static func bookmark(_ url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let f = try? JSONDecoder().decode(FileFormat.self, from: data) else { return }
        var repaired = false
        entries = f.favorites.map { e in
            var e = e
            if !FileManager.default.fileExists(atPath: e.path), let b = e.bookmark {
                var stale = false
                if let u = try? URL(resolvingBookmarkData: b, options: [.withoutUI], relativeTo: nil,
                                    bookmarkDataIsStale: &stale), u.path != e.path {
                    e.path = u.path
                    e.bookmark = Self.bookmark(u) ?? b
                    repaired = true
                }
            }
            return e
        }
        if repaired { save() }
    }

    private func reloadIfChanged() {
        let before = entries.map(\.path)
        load()
        if entries.map(\.path) != before { NotificationCenter.default.post(name: .pinnedChanged, object: nil) }
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        if let data = try? enc.encode(FileFormat(favorites: entries)) {
            try? data.write(to: fileURL, options: .atomic)
        }
        NotificationCenter.default.post(name: .pinnedChanged, object: nil)
    }

    func contains(_ url: URL) -> Bool { entries.contains { $0.path == url.standardizedFileURL.path } }

    func add(_ urls: [URL], at index: Int? = nil) {
        var i = min(index ?? entries.count, entries.count)
        for u in urls.map(\.standardizedFileURL) where !contains(u) {
            entries.insert(Entry(path: u.path, bookmark: Self.bookmark(u)), at: i)
            i += 1
        }
        save()
    }

    func remove(_ url: URL) {
        entries.removeAll { $0.path == url.standardizedFileURL.path }
        save()
    }

    func move(from: Int, to: Int) {
        guard entries.indices.contains(from) else { return }
        let e = entries.remove(at: from)
        entries.insert(e, at: min(max(0, from < to ? to - 1 : to), entries.count))
        save()
    }
}

// MARK: - Seitenleiste

enum SidebarRow {
    case header(String)
    case place(title: String, url: URL, symbol: String, pinned: Bool)
    case hint(String)

    var url: URL? {
        if case let .place(_, url, _, _) = self { return url }
        return nil
    }
}

// MARK: - Explorer-Bereich (ein Fenster enthält einen oder zwei davon)

final class ExplorerController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
                                NSTextFieldDelegate, NSSearchFieldDelegate, NSMenuDelegate, NSMenuItemValidation,
                                QLPreviewPanelDataSource, QLPreviewPanelDelegate {

    private(set) var currentDir: URL
    private var items: [FileItem] = []
    private var shown: [FileItem] = []
    private var backStack: [URL] = []
    private var forwardStack: [URL] = []
    private var showHidden = UserDefaults.standard.bool(forKey: "showHidden")
    private let watcher = DirWatcher()
    private var reloadWork: DispatchWorkItem?
    private var renamingURL: URL?
    private var busyCount = 0
    private var suppressSidebarNav = false
    private var observers: [NSObjectProtocol] = []
    // Volltextsuche (Spotlight) im aktuellen Ordner inkl. Unterordnern
    private var deepQuery: NSMetadataQuery?
    private var deepTerm = ""
    private var deepObservers: [NSObjectProtocol] = []
    private var deepRefreshPending = false
    private var rowIndex: [String: Int] = [:]    // Pfad → Zeile, für gezielte Aktualisierung der Größen
    private let maxDeepResults = 5000
    var isDeepSearch: Bool { deepQuery != nil }
    var window: NSWindow? { view.window }
    private let headerLabel = NSTextField(labelWithString: "")
    private var sidebarScroll: NSScrollView!
    private var sidebarMinWidth: NSLayoutConstraint!
    private var sidebarBtn: NSButton!
    private var sidebarWidthBeforeHide: CGFloat = 210
    private var sidebarDefaultBackground: NSColor?
    private let cockpitBar = CategoryBar()
    private let cockpitLabel = NSTextField(labelWithString: "")
    private var cockpitScheduled = false
    private var cockpitDefaultsKey: String { side == 1 ? "cockpitHiddenRight" : "cockpitHiddenLeft" }
    private let headerDot = NSImageView()
    /// 0 = linker, 1 = rechter Bereich
    var side = 0 { didSet { updateHeader(); applyPaneColor(); applySidebarVisibility() } }
    var sideName: String { side == 1 ? L("Right pane") : L("Left pane") }
    private var sidebarDefaultsKey: String { side == 1 ? "sidebarHiddenRight" : "sidebarHiddenLeft" }
    var isActivePane = true { didSet { updateHeader() } }
    var explorerWindow: ExplorerWindow? { window?.windowController as? ExplorerWindow }

    let table = FileTableView()
    let sidebar = NSTableView()
    let split = NSSplitView()
    let addressField = NSTextField()
    let searchField = NSSearchField()
    let statusLabel = NSTextField(labelWithString: "")
    let spinner = NSProgressIndicator()
    let fileMenu = NSMenu()
    let sidebarMenu = NSMenu()
    private var backBtn: NSButton!
    private var fwdBtn: NSButton!
    private var upBtn: NSButton!
    private var termBtn: NSButton!
    private var sidebarRows: [SidebarRow] = []

    init(dir: URL, width: CGFloat = 1100) {
        currentDir = dir
        super.init(nibName: nil, bundle: nil)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 680))
        view = root
        buildUI(root)
        buildSidebar()
        sidebar.reloadData()
        root.layoutSubtreeIfNeeded()
        split.setPosition(min(210, width * 0.3), ofDividerAt: 0)
        fitColumns()
        navigate(to: dir, addHistory: false)
        observe()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: UI-Aufbau

    private func makeButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage()
        let b = NSButton(image: img, target: self, action: action)
        b.bezelStyle = .texturedRounded
        b.toolTip = tip
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 32).isActive = true
        return b
    }

    private func buildUI(_ root: NSView) {
        // Navigationsleiste
        sidebarBtn = makeButton("sidebar.left", L("Show/hide sidebar (⌃⌘S)"), #selector(toggleFavoritesSidebar(_:)))
        backBtn = makeButton("chevron.left", L("Back (Alt+← / Backspace)"), #selector(goBack))
        fwdBtn = makeButton("chevron.right", L("Forward (Alt+→)"), #selector(goForward))
        upBtn = makeButton("arrow.up", L("Parent folder (Alt+↑)"), #selector(goUp))
        let refreshBtn = makeButton("arrow.clockwise", L("Refresh (F5)"), #selector(reload))
        let copyBtn = makeButton("doc.on.doc", L("Copy path of this folder"), #selector(copyCurrentFolderPath(_:)))
        termBtn = makeButton("terminal", "", #selector(openTerminal(_:)))
        let splitBtn = makeButton("rectangle.split.2x1", L("Show/hide second pane (⌥⌘S) – left only ⌥⌘←, right only ⌥⌘→"), #selector(toggleSplitFromPane(_:)))
        termBtn.menu = TerminalChooser.shared.makeMenu()
        updateTerminalTip()
        NotificationCenter.default.addObserver(forName: .terminalChoiceChanged, object: nil, queue: .main) { [weak self] _ in
            self?.updateTerminalTip()
        }

        addressField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        addressField.placeholderString = L("Type a path and press Enter (Ctrl+L)")
        addressField.delegate = self
        addressField.lineBreakMode = .byTruncatingHead
        addressField.cell?.isScrollable = true
        addressField.cell?.wraps = false
        addressField.cell?.usesSingleLineMode = true
        addressField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addressField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        searchField.placeholderString = L("Search – Enter: also contents & subfolders")
        searchField.toolTip = L("Typing filters the current folder. Enter searches all subfolders with Spotlight, including file contents. Esc ends the search.")
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.translatesAutoresizingMaskIntoConstraints = false
        let sw = searchField.widthAnchor.constraint(equalToConstant: 220)
        sw.priority = .defaultLow
        sw.isActive = true
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true

        let nav = NSStackView(views: [sidebarBtn, backBtn, fwdBtn, upBtn, refreshBtn, addressField, copyBtn, termBtn, searchField, splitBtn])
        nav.orientation = .horizontal
        nav.spacing = 6
        nav.alignment = .centerY
        nav.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)

        // Seitenleiste
        let sbCol = NSTableColumn(identifier: .init("sidebar"))
        sbCol.resizingMask = .autoresizingMask
        sidebar.addTableColumn(sbCol)
        sidebar.headerView = nil
        sidebar.style = .sourceList
        sidebar.rowHeight = 24
        sidebar.dataSource = self
        sidebar.delegate = self
        sidebar.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        sidebarMenu.delegate = self
        sidebar.menu = sidebarMenu
        sidebar.registerForDraggedTypes([.fileURL, Favorites.dragType])
        sidebar.setDraggingSourceOperationMask(.move, forLocal: true)
        sidebar.setDraggingSourceOperationMask([], forLocal: false)
        let sbScroll = NSScrollView()
        sidebarScroll = sbScroll
        sbScroll.documentView = sidebar
        sbScroll.hasVerticalScroller = true
        sbScroll.autohidesScrollers = true
        sbScroll.drawsBackground = false

        // Dateiliste
        table.explorer = self
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.style = .fullWidth
        table.rowHeight = 22
        table.intercellSpacing = NSSize(width: 6, height: 2)
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        let cols: [(String, String, CGFloat)] = [("name", L("Name"), 380), ("date", L("Date Modified"), 150),
                                                 ("kind", L("Type"), 170), ("size", L("Size"), 90)]
        for (id, title, width) in cols {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = width
            c.minWidth = 60
            c.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            if id == "size" { c.headerCell.alignment = .right }
            table.addTableColumn(c)
        }
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        table.autosaveName = "ExplorerFileColumns"
        table.autosaveTableColumns = true
        // Anzahl Dateien (bei Ordnern inkl. Unterordnern, im Hintergrund berechnet)
        if table.tableColumn(withIdentifier: .init("files")) == nil {
            let fc = NSTableColumn(identifier: .init("files"))
            fc.title = L("Files")
            fc.width = 80
            fc.minWidth = 50
            fc.headerCell.alignment = .right
            fc.sortDescriptorPrototype = NSSortDescriptor(key: "files", ascending: false)
            table.addTableColumn(fc)
        }
        // Nur während der Volltextsuche sichtbar: in welchem Unterordner der Treffer liegt
        let folderCol = NSTableColumn(identifier: .init("folder"))
        folderCol.title = L("Folder")
        folderCol.width = 220
        folderCol.minWidth = 60
        folderCol.sortDescriptorPrototype = NSSortDescriptor(key: "folder", ascending: true)
        table.addTableColumn(folderCol)
        table.moveColumn(table.numberOfColumns - 1, toColumn: 1)
        folderCol.isHidden = true
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
        table.draggingDestinationFeedbackStyle = .regular
        fileMenu.delegate = self
        table.menu = fileMenu
        let fileScroll = NSScrollView()
        fileScroll.documentView = table
        fileScroll.hasVerticalScroller = true
        // Kein waagerechter Scrollbalken: die Namensspalte passt sich der Breite an. Ein ein-/ausblendender
        // Balken würde die Höhe ändern und mit der Spaltenanpassung eine Layout-Endlosschleife erzeugen.
        fileScroll.hasHorizontalScroller = false
        fileScroll.autohidesScrollers = true
        // Namensspalte passt sich der Breite an, damit Größe/Dateien immer sichtbar bleiben
        fileScroll.contentView.postsFrameChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification,
                                                                object: fileScroll.contentView, queue: .main) { [weak self] _ in
            self?.scheduleFitColumns()
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSTableView.columnDidResizeNotification,
                                                                object: table, queue: .main) { [weak self] n in
            // Nur wenn eine andere Spalte als „Name“ verändert wurde, Name nachziehen
            guard let self = self, !self.fittingColumns,
                  let col = n.userInfo?["NSTableColumn"] as? NSTableColumn, col.identifier.rawValue != "name" else { return }
            if NSEvent.pressedMouseButtons & 1 != 0 { self.naturalWidths[col.identifier.rawValue] = col.width }
            self.scheduleFitColumns(force: true)
        })

        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(sbScroll)
        split.addArrangedSubview(fileScroll)
        split.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)
        split.setHoldingPriority(NSLayoutConstraint.Priority(250), forSubviewAt: 1)
        sbScroll.translatesAutoresizingMaskIntoConstraints = false
        sidebarMinWidth = sbScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 140)
        sidebarMinWidth.isActive = true

        // Statusleiste
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let status = NSStackView(views: [spinner, statusLabel])
        cockpitLabel.textColor = .secondaryLabelColor
        cockpitLabel.lineBreakMode = .byTruncatingTail
        cockpitLabel.setContentCompressionResistancePriority(.init(240), for: .horizontal)
        cockpitBar.setContentCompressionResistancePriority(.init(260), for: .horizontal)
        status.addView(cockpitBar, in: .trailing)
        status.addView(cockpitLabel, in: .trailing)
        status.orientation = .horizontal
        status.spacing = 6
        status.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 5, right: 10)

        let sep1 = NSBox(); sep1.boxType = .separator
        let sep2 = NSBox(); sep2.boxType = .separator

        // Kopfzeile: „Linker Bereich“ / „Rechter Bereich“, aktiver Bereich farbig
        headerLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        headerDot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        headerDot.symbolConfiguration = .init(pointSize: 7, weight: .regular)
        observers.append(NotificationCenter.default.addObserver(forName: .zoomChanged, object: nil, queue: .main) { [weak self] n in
            self?.applyZoom(oldFactor: n.userInfo?["old"] as? CGFloat)
        })
        let header = NSStackView(views: [headerDot, headerLabel])
        header.orientation = .horizontal
        header.spacing = 5
        header.alignment = .centerY
        header.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 0, right: 10)
        updateHeader()

        applyZoom(oldFactor: nil)
        observers.append(NotificationCenter.default.addObserver(forName: .paneColorsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.applyPaneColor()
        })

        let stack: [NSView] = [header, nav, sep1, split, sep2, status]
        for v in stack {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
            v.leadingAnchor.constraint(equalTo: root.leadingAnchor).isActive = true
            v.trailingAnchor.constraint(equalTo: root.trailingAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            nav.topAnchor.constraint(equalTo: header.bottomAnchor),
            sep1.topAnchor.constraint(equalTo: nav.bottomAnchor),
            split.topAnchor.constraint(equalTo: sep1.bottomAnchor),
            sep2.topAnchor.constraint(equalTo: split.bottomAnchor),
            status.topAnchor.constraint(equalTo: sep2.bottomAnchor),
            status.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
    }

    private func observe() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .fileClipboardChanged, object: nil, queue: .main) { [weak self] _ in
            self?.refreshVisibleCells()
        })
        observers.append(nc.addObserver(forName: .folderStatsInvalidated, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.renamingURL == nil else { return }
            self.refreshVisibleCells()
            self.requestFolderStats()
        })
        observers.append(nc.addObserver(forName: .pinnedChanged, object: nil, queue: .main) { [weak self] _ in
            self?.rebuildSidebar()
        })
        let wnc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(wnc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.rebuildSidebar()
            })
        }
    }

    // MARK: Seitenleiste

    private func buildSidebar() {
        let fm = FileManager.default
        var rows: [SidebarRow] = []
        func add(_ title: String, _ url: URL?, _ symbol: String, pinned: Bool = false) {
            guard let url = url, fm.fileExists(atPath: url.path) else { return }
            rows.append(.place(title: title, url: url, symbol: symbol, pinned: pinned))
        }
        rows.append(.header(L("Favorites")))
        let favs = Favorites.shared.urls
        if favs.isEmpty {
            rows.append(.hint(L("Drag folders here or press ⌃⌘T")))
        } else {
            for u in favs {
                let exists = fm.fileExists(atPath: u.path)
                rows.append(.place(title: fm.displayName(atPath: u.path), url: u,
                                   symbol: exists ? "star.fill" : "exclamationmark.triangle", pinned: true))
            }
        }

        rows.append(.header(L("Quick Access")))
        let home = fm.homeDirectoryForCurrentUser
        func user(_ d: FileManager.SearchPathDirectory) -> URL? { fm.urls(for: d, in: .userDomainMask).first }
        add(L("Home"), home, "house")
        add(L("Desktop"), user(.desktopDirectory), "desktopcomputer")
        add(L("Documents"), user(.documentDirectory), "doc")
        add(L("Downloads"), user(.downloadsDirectory), "arrow.down.circle")
        add(L("Pictures"), user(.picturesDirectory), "photo")
        add(L("Music"), user(.musicDirectory), "music.note")
        add(L("Movies"), user(.moviesDirectory), "film")
        add(L("Applications"), URL(fileURLWithPath: "/Applications"), "square.grid.2x2")
        add("iCloud Drive", home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs"), "icloud")

        rows.append(.header(L("Drives")))
        let vols = fm.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeLocalizedNameKey],
                                        options: [.skipHiddenVolumes]) ?? []
        for v in vols {
            let name = (try? v.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName
                ?? v.lastPathComponent
            add(name, v, v.path == "/" ? "internaldrive" : "externaldrive")
        }
        sidebarRows = rows
    }

    private func rebuildSidebar() {
        buildSidebar()
        sidebar.reloadData()
        syncSidebarSelection()
    }

    private func syncSidebarSelection() {
        suppressSidebarNav = true
        defer { suppressSidebarNav = false }
        let cur = FileOps.canonical(currentDir)
        if let idx = sidebarRows.firstIndex(where: { $0.url.map(FileOps.canonical) == cur }) {
            sidebar.selectRowIndexes([idx], byExtendingSelection: false)
        } else {
            sidebar.deselectAll(nil)
        }
    }

    // MARK: Navigation

    var selectedItems: [FileItem] {
        table.selectedRowIndexes.compactMap { $0 < shown.count ? shown[$0] : nil }
    }

    var selectedURLs: [URL] { selectedItems.map(\.url) }

    func navigate(to url: URL, addHistory: Bool = true, select: [URL] = []) {
        let u = url.standardizedFileURL
        guard FileOps.isDir(u) else {
            showError(L("“%@” is not a folder or does not exist.", u.path))
            return
        }
        let list: [FileItem]
        do {
            list = try loadItems(u)
        } catch {
            showError(L("“%@” cannot be accessed.", u.path) + "\n" + error.localizedDescription)
            return
        }
        if addHistory && u.path != currentDir.path {
            backStack.append(currentDir)
            forwardStack.removeAll()
        }
        stopDeepQuery()
        FolderSizer.shared.cancel(owner: self)
        currentDir = u
        items = list
        searchField.stringValue = ""
        applyFilterAndSort(select: select)
        if select.isEmpty, !shown.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
        updateChrome()
        watcher.watch(u) { [weak self] in self?.scheduleReload() }
    }

    private func loadItems(_ dir: URL) throws -> [FileItem] {
        let urls = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: FileItem.keys,
                                                               options: [])
        return urls.map(FileItem.init(url:))
    }

    private func scheduleReload() {
        reloadWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.reloadItems(select: nil) }
        reloadWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
    }

    /// F5 / ⌘R: Ordner neu laden und Ordnergrößen neu berechnen.
    @objc func reload() {
        FolderSizer.shared.invalidate(under: currentDir)
        reloadItems(select: nil)
    }

    func reloadItems(select: [URL]?) {
        guard renamingURL == nil else { return }
        if isDeepSearch { refreshDeepResults(select: select); return }
        guard FileOps.isDir(currentDir) else {
            // Ordner wurde gelöscht → nach oben gehen
            var p = currentDir.deletingLastPathComponent()
            while !FileOps.isDir(p) && p.path != "/" { p = p.deletingLastPathComponent() }
            navigate(to: p, addHistory: false)
            return
        }
        items = (try? loadItems(currentDir)) ?? []
        applyFilterAndSort(select: select)
    }

    private func applyFilterAndSort(select urls: [URL]?) {
        let keep = Set((urls ?? selectedURLs).map { $0.standardizedFileURL.path })
        let q = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        var list = items.filter { showHidden || !$0.hidden }
        if !q.isEmpty, !isDeepSearch { list = list.filter { $0.name.localizedCaseInsensitiveContains(q) } }

        let sd = table.sortDescriptors.first ?? NSSortDescriptor(key: "name", ascending: true)
        let asc = sd.ascending
        let key = sd.key ?? "name"
        list.sort { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }   // Ordner immer zuerst
            var r: ComparisonResult = .orderedSame
            switch key {
            case "date": r = a.modified.compare(b.modified)
            case "size":
                let sa = sizeValue(a), sb = sizeValue(b)
                r = sa == sb ? .orderedSame : (sa < sb ? .orderedAscending : .orderedDescending)
            case "files":
                let fa = fileCount(a), fb = fileCount(b)
                r = fa == fb ? .orderedSame : (fa < fb ? .orderedAscending : .orderedDescending)
            case "kind": r = a.kind.localizedStandardCompare(b.kind)
            case "folder": r = relativeFolder(a).localizedStandardCompare(relativeFolder(b))
            default: break
            }
            if r == .orderedSame { r = a.name.localizedStandardCompare(b.name) }
            return asc ? r == .orderedAscending : r == .orderedDescending
        }
        shown = list
        rowIndex = Dictionary(shown.enumerated().map { ($1.url.standardizedFileURL.path, $0) },
                              uniquingKeysWith: { a, _ in a })
        table.reloadData()
        autoFitColumns()
        requestFolderStats()

        var idx = IndexSet()
        for (i, it) in shown.enumerated() where keep.contains(it.url.standardizedFileURL.path) { idx.insert(i) }
        table.selectRowIndexes(idx, byExtendingSelection: false)
        if let first = idx.first { table.scrollRowToVisible(first) }
        updateStatus()
    }

    private func updateChrome() {
        explorerWindow?.updateTitle()
        addressField.stringValue = currentDir.path
        backBtn.isEnabled = !backStack.isEmpty
        fwdBtn.isEnabled = !forwardStack.isEmpty
        upBtn.isEnabled = currentDir.path != "/"
        syncSidebarSelection()
    }

    // MARK: Zoom

    /// Schriften, Zeilenhöhen und Symbole an den Zoomfaktor anpassen. Bei einer Änderung
    /// werden die Spalten (außer Name) mitskaliert; Name füllt den Rest.
    private func applyZoom(oldFactor: CGFloat?) {
        let z = Zoom.factor
        table.rowHeight = Zoom.s(22)
        sidebar.rowHeight = Zoom.s(24)
        addressField.font = .monospacedSystemFont(ofSize: 12 * z, weight: .regular)
        searchField.font = .systemFont(ofSize: 13 * z)
        statusLabel.font = .systemFont(ofSize: 11 * z)
        cockpitLabel.font = .systemFont(ofSize: 11 * z)
        cockpitBar.invalidateIntrinsicContentSize()
        headerLabel.font = .systemFont(ofSize: 11 * z, weight: .semibold)
        headerDot.symbolConfiguration = .init(pointSize: 7 * z, weight: .regular)
        let headerFont = NSFont.systemFont(ofSize: 11 * z)
        for c in table.tableColumns {
            c.headerCell.font = headerFont
            if let old = oldFactor, old > 0, c.identifier.rawValue != "name" {
                c.width = max(c.minWidth, (c.width * z / old).rounded())
            }
        }
        if let h = table.headerView {
            h.frame.size.height = max(Zoom.s(17), 17)
            h.needsDisplay = true
        }
        guard oldFactor != nil else { return }
        let sel = table.selectedRowIndexes
        table.reloadData()
        table.selectRowIndexes(sel, byExtendingSelection: false)
        sidebar.reloadData()
        syncSidebarSelection()
        table.tile()
        autoFitColumns()
        if let first = sel.first { table.scrollRowToVisible(first) }
        updateStatus()
    }

    // MARK: Spaltenbreiten

    private var fittingColumns = false
    private var fitScheduled = false
    private var lastFitWidth: CGFloat = -1

    /// Anpassung erst nach dem laufenden Layout-Durchlauf und nur bei echter Breitenänderung.
    private func scheduleFitColumns(force: Bool = false) {
        if force { lastFitWidth = -1 }
        guard !fitScheduled else { return }
        fitScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.fitScheduled = false
            let w = self.table.enclosingScrollView?.contentView.bounds.width ?? 0
            guard abs(w - self.lastFitWidth) > 0.5 else { return }
            self.fitColumns()
        }
    }

    /// Namensspalte so breit machen, dass alle anderen sichtbaren Spalten ohne Scrollen passen.
    /// Angezeigter Text einer Zelle (auch für die Breitenmessung).
    func cellText(_ col: String, _ item: FileItem) -> String {
        switch col {
        case "date":
            return item.modified == .distantPast ? "" : dateFormatter.string(from: item.modified)
        case "kind":
            return item.kind
        case "folder":
            let rel = relativeFolder(item)
            return rel.isEmpty ? L("(here)") : rel
        case "files":
            guard item.isDirectory else { return "" }
            guard let st = FolderSizer.shared.stats(item.url) else { return "…" }
            return (st.partial ? "≥ " : "") + (countFormatter.string(from: NSNumber(value: st.files)) ?? "\(st.files)")
        case "size":
            guard item.isDirectory else { return sizeFormatter.string(fromByteCount: item.size) }
            guard let st = FolderSizer.shared.stats(item.url) else { return "…" }
            return (st.partial ? "≥ " : "") + sizeFormatter.string(fromByteCount: st.bytes)
        default:
            return item.name
        }
    }

    /// „Natürliche“ Breite je Spalte: längster Eintrag bzw. Überschrift – nicht breiter als nötig.
    private var naturalWidths: [String: CGFloat] = [:]
    private var autoFitScheduled = false

    private func scheduleAutoFit() {
        guard !autoFitScheduled else { return }
        autoFitScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.autoFitScheduled = false
            self?.autoFitColumns()
        }
    }

    func autoFitColumns() {
        let font = NSFont.systemFont(ofSize: 13 * Zoom.factor)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let caps: [String: CGFloat] = ["kind": Zoom.s(240), "folder": Zoom.s(320), "date": Zoom.s(200)]
        for id in ["date", "kind", "size", "files", "folder"] {
            guard let c = table.tableColumn(withIdentifier: .init(id)) else { continue }
            let headerFont = c.headerCell.font ?? NSFont.systemFont(ofSize: 11 * Zoom.factor)
            var w = (c.title as NSString).size(withAttributes: [.font: headerFont]).width + Zoom.s(22)   // + Sortierpfeil
            var seen = Set<String>()
            for it in shown {
                let t = cellText(id, it)
                guard !t.isEmpty, seen.insert(t).inserted else { continue }
                w = max(w, (t as NSString).size(withAttributes: attrs).width + Zoom.s(10))
                if seen.count > 3000 { break }
            }
            naturalWidths[id] = min(ceil(w), caps[id] ?? .greatestFiniteMagnitude)
        }
        fitColumns()
    }

    /// Spalten auf ihre natürliche Breite setzen; „Name“ bekommt den Rest. Bei Platzmangel werden
    /// zuerst Typ, dann Ordner und Datum schmaler, damit der Name lesbar bleibt.
    func fitColumns() {
        guard !fittingColumns, let name = table.tableColumn(withIdentifier: .init("name")),
              let clip = table.enclosingScrollView?.contentView, clip.bounds.width > 0 else { return }
        fittingColumns = true
        defer { fittingColumns = false }
        let visible = table.tableColumns.filter { !$0.isHidden }
        let spacing = table.intercellSpacing.width * CGFloat(visible.count)
        lastFitWidth = clip.bounds.width
        var widths: [String: CGFloat] = [:]
        for c in visible where c !== name {
            widths[c.identifier.rawValue] = naturalWidths[c.identifier.rawValue] ?? c.width
        }
        let wantName = Zoom.s(180)
        var missing = wantName - (clip.bounds.width - widths.values.reduce(0, +) - spacing - 2)
        for (id, floorWidth) in [("kind", Zoom.s(60)), ("folder", Zoom.s(80)), ("date", Zoom.s(95))] where missing > 0 {
            guard let w = widths[id], w > floorWidth else { continue }
            let cut = min(missing, w - floorWidth)
            widths[id] = w - cut
            missing -= cut
        }
        for c in visible where c !== name {
            if let w = widths[c.identifier.rawValue], abs(c.width - w) > 0.5 { c.width = w }
        }
        let target = max(name.minWidth, floor(clip.bounds.width - widths.values.reduce(0, +) - spacing - 2))
        if abs(name.width - target) > 0.5 { name.width = target }
    }

    // MARK: Cockpit (Ordner-Übersicht in der Statuszeile)

    /// ⌃⌘I: Übersicht in der Statuszeile dieses Bereichs ein-/ausblenden.
    @objc func toggleCockpit(_ sender: Any?) {
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: cockpitDefaultsKey), forKey: cockpitDefaultsKey)
        updateCockpit()
    }

    private func scheduleCockpit() {
        guard !cockpitScheduled else { return }
        cockpitScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.cockpitScheduled = false
            self?.updateCockpit()
        }
    }

    /// Fasst Ordner (inkl. Unterordner) bzw. – bei ≥ 2 markierten Einträgen – die Auswahl nach
    /// Kategorien zusammen. Ordnerwerte kommen aus der Hintergrundberechnung; noch offene Ordner
    /// werden als „rechnet …“ angezeigt.
    private func updateCockpit() {
        let hidden = UserDefaults.standard.bool(forKey: cockpitDefaultsKey) || isDeepSearch
        cockpitBar.isHidden = hidden
        cockpitLabel.isHidden = hidden
        guard !hidden else { return }

        let sel = selectedItems
        let useSelection = sel.count >= 2
        let source = useSelection ? sel : items.filter { showHidden || !$0.hidden }
        let n = FileCategory.allCases.count
        var bytes = Array(repeating: Int64(0), count: n)
        var counts = Array(repeating: 0, count: n)
        var pending = 0
        for it in source {
            if it.isDirectory {
                guard let st = FolderSizer.shared.stats(it.url) else { pending += 1; continue }
                if !it.isFolder {                                   // Bundle (.app, .logicx …) als Ganzes
                    let c = FileCategory.of(it.url)
                    bytes[c.rawValue] += st.bytes
                    counts[c.rawValue] += 1
                } else {
                    for i in 0..<n { bytes[i] += st.catBytes[i]; counts[i] += st.catCounts[i] }
                }
            } else {
                let c = FileCategory.of(it.url)
                bytes[c.rawValue] += it.size
                counts[c.rawValue] += 1
            }
        }
        let total = bytes.reduce(0, +)
        let order = FileCategory.allCases.filter { bytes[$0.rawValue] > 0 }
            .sorted { bytes[$0.rawValue] > bytes[$1.rawValue] }
        cockpitBar.parts = order.map { ($0.color, CGFloat(bytes[$0.rawValue])) }

        func pct(_ c: FileCategory) -> String {
            let p = total > 0 ? Double(bytes[c.rawValue]) / Double(total) * 100 : 0
            return p >= 1 ? "\(Int(p.rounded())) %" : "< 1 %"
        }
        var text = order.prefix(3).map { "\($0.title) \(pct($0))" }.joined(separator: " · ")
        if text.isEmpty { text = pending > 0 ? "" : L("empty") }
        let totalText = sizeFormatter.string(fromByteCount: total)
        text += (text.isEmpty ? "" : "  ") + (pending > 0 ? L("≥ %@ · calculating …", totalText) : totalText)
        if useSelection { text = L("Selection: %@", text) }
        cockpitLabel.stringValue = text

        var tip = useSelection ? L("Selection (%ld items)", sel.count) : L("This folder including subfolders")
        tip += "\n"
        for c in order {
            tip += "\n\(c.title): \(sizeFormatter.string(fromByteCount: bytes[c.rawValue])) (\(pct(c))), " + L("%ld files", counts[c.rawValue])
        }
        if pending > 0 { tip += "\n\n" + L("%ld folders still being calculated …", pending) }
        tip += "\n\n" + L("Show/hide: ⌃⌘I")
        cockpitLabel.toolTip = tip
        cockpitBar.toolTip = tip
    }

    // MARK: Ordnergrößen

    private func sizeValue(_ it: FileItem) -> Int64 {
        it.isDirectory ? (FolderSizer.shared.stats(it.url)?.bytes ?? -1) : it.size
    }

    private func fileCount(_ it: FileItem) -> Int {
        it.isDirectory ? (FolderSizer.shared.stats(it.url)?.files ?? -1) : 0
    }

    /// Größen aller angezeigten Ordner im Hintergrund anfordern; fertige Werte erscheinen einzeln.
    private func requestFolderStats() {
        let dirs = shown.filter { $0.isDirectory }.map(\.url)
        guard !dirs.isEmpty else { return }
        FolderSizer.shared.request(dirs, owner: self) { [weak self] path, _ in
            self?.folderStatsArrived(path)
        }
    }

    private func folderStatsArrived(_ path: String) {
        guard let row = rowIndex[path], row < shown.count, renamingURL == nil else { return }
        let cols = IndexSet(["size", "files"].compactMap {
            let c = table.column(withIdentifier: .init($0)); return c >= 0 ? c : nil
        })
        table.reloadData(forRowIndexes: [row], columnIndexes: cols)
        if table.selectedRowIndexes.contains(row) { updateStatus() }
        scheduleAutoFit()
        scheduleCockpit()
    }

    private func updateStatus() {
        guard busyCount == 0 else { return }
        var s = L("%ld items", shown.count)
        if let q = deepQuery {
            let n = shown.count
            s = q.isGathering ? L("Searching “%@” … found so far: %ld", deepTerm, n)
                : n == 0 ? L("No results for “%@” (only files indexed by Spotlight) – Esc ends the search", deepTerm)
                : L("Results for “%@” in names and content, including subfolders: %@ – Esc ends the search",
                    deepTerm, L("%ld", n) + (n >= maxDeepResults ? "+" : ""))
        }
        let sel = selectedItems
        if !sel.isEmpty {
            s += "   |   " + L("%ld selected", sel.count)
            let bytes = sel.reduce(Int64(0)) { $0 + max(0, sizeValue($1)) }
            if bytes > 0 { s += "  (\(sizeFormatter.string(fromByteCount: bytes)))" }
        }
        if FileClipboard.isCutActive { s += "   |   " + L("%ld cut", FileClipboard.cutURLs.count) }
        statusLabel.stringValue = s
        updateCockpit()
    }

    private func flashStatus(_ text: String) {
        statusLabel.stringValue = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.updateStatus() }
    }

    private func refreshVisibleCells() {
        guard renamingURL == nil, !shown.isEmpty else { updateStatus(); return }
        table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<shown.count),
                         columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        updateStatus()
    }

    @objc func goBack() {
        if isDeepSearch { endDeepSearch(); return }
        guard let prev = backStack.popLast() else { NSSound.beep(); return }
        forwardStack.append(currentDir)
        navigate(to: prev, addHistory: false, select: [currentDir])
    }

    @objc func goForward() {
        guard let next = forwardStack.popLast() else { NSSound.beep(); return }
        backStack.append(currentDir)
        navigate(to: next, addHistory: false)
    }

    @objc func goUp() {
        guard currentDir.path != "/" else { NSSound.beep(); return }
        let child = currentDir
        navigate(to: currentDir.deletingLastPathComponent(), select: [child])
    }

    @objc func goHome(_ sender: Any?) { navigate(to: FileManager.default.homeDirectoryForCurrentUser) }

    @objc func goDownloads(_ sender: Any?) {
        if let u = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first { navigate(to: u) }
    }

    @objc func goDesktop(_ sender: Any?) {
        if let u = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first { navigate(to: u) }
    }

    @objc func goApplications(_ sender: Any?) { navigate(to: URL(fileURLWithPath: "/Applications")) }

    @objc func focusAddress(_ sender: Any?) {
        window?.makeFirstResponder(addressField)
        addressField.currentEditor()?.selectAll(nil)
    }

    @objc func focusSearch(_ sender: Any?) { window?.makeFirstResponder(searchField) }

    @objc func searchChanged(_ sender: Any?) {
        if isDeepSearch {
            guard searchField.stringValue.trimmingCharacters(in: .whitespaces) != deepTerm else { return }
            stopDeepQuery()
            items = (try? loadItems(currentDir)) ?? []
        }
        applyFilterAndSort(select: nil)
    }

    // MARK: Volltextsuche (Spotlight)

    func startDeepSearch(_ term: String) {
        stopDeepQuery()
        let q = NSMetadataQuery()
        q.searchScopes = [currentDir]
        q.predicate = Self.spotlightPredicate(term)
        q.notificationBatchingInterval = 0.3
        let nc = NotificationCenter.default
        for name in [Notification.Name.NSMetadataQueryGatheringProgress, .NSMetadataQueryDidFinishGathering,
                     .NSMetadataQueryDidUpdate] {
            deepObservers.append(nc.addObserver(forName: name, object: q, queue: .main) { [weak self] n in
                self?.deepQueryChanged(finished: n.name == .NSMetadataQueryDidFinishGathering)
            })
        }
        deepQuery = q
        deepTerm = term
        items = []
        if let col = table.tableColumn(withIdentifier: .init("folder")) { col.isHidden = false }
        fitColumns()
        spinner.startAnimation(nil)
        applyFilterAndSort(select: [])
        if !q.start() { stopDeepQuery(); showError(L("The Spotlight search could not be started.")) }
    }

    /// Name enthält den Suchbegriff ODER der Dateiinhalt enthält alle Wörter (Wortanfang).
    static func spotlightPredicate(_ term: String) -> NSPredicate {
        func esc(_ t: String) -> String {
            t.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
             .replacingOccurrences(of: "*", with: "\\*")
        }
        let words = term.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let name = "kMDItemFSName == \"*\(esc(term))*\"cd"
        let content = words.map { "kMDItemTextContent == \"\(esc($0))*\"cdw" }.joined(separator: " && ")
        let query = words.isEmpty ? name : "\(name) || (\(content))"
        return NSPredicate(fromMetadataQueryString: query)
            ?? NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, term)
    }

    private func deepQueryChanged(finished: Bool) {
        if finished { spinner.stopAnimation(nil); refreshDeepResults(select: nil); return }
        // Während des Sammelns höchstens alle 0,4 s neu zeichnen
        guard !deepRefreshPending else { return }
        deepRefreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.deepRefreshPending = false
            self?.refreshDeepResults(select: nil)
        }
    }

    private func refreshDeepResults(select: [URL]?) {
        guard let q = deepQuery else { return }
        q.disableUpdates()
        let n = min(q.resultCount, maxDeepResults)
        var urls: [URL] = []
        urls.reserveCapacity(n)
        for i in 0..<n {
            if let item = q.result(at: i) as? NSMetadataItem,
               let path = item.value(forAttribute: NSMetadataItemPathKey) as? String {
                urls.append(URL(fileURLWithPath: path))
            }
        }
        q.enableUpdates()
        let fm = FileManager.default
        items = urls.filter { fm.fileExists(atPath: $0.path) }.map(FileItem.init(url:))
        applyFilterAndSort(select: select)
    }

    private func stopDeepQuery() {
        guard let q = deepQuery else { return }
        q.stop()
        deepObservers.forEach { NotificationCenter.default.removeObserver($0) }
        deepObservers.removeAll()
        deepQuery = nil
        deepTerm = ""
        spinner.stopAnimation(nil)
        if let col = table.tableColumn(withIdentifier: .init("folder")) { col.isHidden = true }
        fitColumns()
    }

    /// Suche beenden und wieder den Ordnerinhalt zeigen.
    @objc func endDeepSearch() {
        guard isDeepSearch else { return }
        let sel = selectedURLs.filter { $0.deletingLastPathComponent().standardizedFileURL == currentDir }
        stopDeepQuery()
        searchField.stringValue = ""
        items = (try? loadItems(currentDir)) ?? []
        applyFilterAndSort(select: sel)
        window?.makeFirstResponder(table)
    }

    /// Ordner des ausgewählten Treffers öffnen und die Datei dort markieren.
    @objc func openContainingFolder(_ sender: Any?) {
        guard let url = selectedURLs.first else { return }
        navigate(to: url.deletingLastPathComponent(), select: [url])
        window?.makeFirstResponder(table)
    }

    private func relativeFolder(_ item: FileItem) -> String {
        let parent = item.url.deletingLastPathComponent().standardizedFileURL.path
        let root = currentDir.standardizedFileURL.path
        if parent == root { return "" }
        if parent.hasPrefix(root + "/") { return String(parent.dropFirst(root.count + 1)) }
        return parent
    }

    @objc func toggleHidden(_ sender: Any?) {
        showHidden.toggle()
        UserDefaults.standard.set(showHidden, forKey: "showHidden")
        applyFilterAndSort(select: nil)
        flashStatus(showHidden ? L("Hidden files are shown") : L("Hidden files are hidden"))
    }

    private func goToAddress() {
        var text = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count >= 2, (text.hasPrefix("\"") && text.hasSuffix("\"")) || (text.hasPrefix("'") && text.hasSuffix("'")) {
            text = String(text.dropFirst().dropLast())
        }
        window?.makeFirstResponder(table)
        if text.isEmpty { addressField.stringValue = currentDir.path; return }
        if ["cmd", "terminal", "powershell"].contains(text.lowercased()) {
            addressField.stringValue = currentDir.path
            openTerminal(nil)
            return
        }
        if text.hasPrefix("file://"), let u = URL(string: text) { text = u.path }
        text = text.replacingOccurrences(of: "\\ ", with: " ")   // aus dem Terminal kopierte Pfade
        text = (text as NSString).expandingTildeInPath
        if !text.hasPrefix("/") { text = currentDir.appendingPathComponent(text).path }
        let url = URL(fileURLWithPath: text)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
            if isDir.boolValue && !NSWorkspace.shared.isFilePackage(atPath: url.path) {
                navigate(to: url)
            } else {
                navigate(to: url.deletingLastPathComponent(), select: [url])
            }
        } else {
            addressField.stringValue = currentDir.path
            showError(L("The path “%@” was not found.", text))
        }
    }

    // MARK: Öffnen

    @objc func doubleClicked() {
        guard table.clickedRow >= 0 else { return }
        openSelection()
    }

    @objc func openSelection() {
        let sel = selectedItems
        guard !sel.isEmpty else { return }
        if sel.count == 1, sel[0].isFolder { navigate(to: sel[0].url); return }
        for it in sel {
            if it.isFolder { openInNewTab(it.url) } else { NSWorkspace.shared.open(it.url) }
        }
    }

    func openInNewTab(_ url: URL) {
        (NSApp.delegate as? AppDelegate)?.openWindow(at: url, tabbedWith: window)
    }

    @objc func openSelectedInNewTab(_ sender: Any?) {
        for it in selectedItems where it.isFolder { openInNewTab(it.url) }
    }

    @objc func openSelectedInNewWindow(_ sender: Any?) {
        for it in selectedItems where it.isFolder { (NSApp.delegate as? AppDelegate)?.openWindow(at: it.url) }
    }

    @objc func openWith(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(selectedURLs, withApplicationAt: app,
                                configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    @objc func openTerminal(_ sender: Any?) {
        var dir = currentDir
        if let it = selectedItems.first, it.isFolder, selectedItems.count == 1, sender is NSMenuItem { dir = it.url }
        TerminalChooser.shared.open(dir)
    }

    private func updateTerminalTip() {
        termBtn?.toolTip = L("Open in %@ (⌥⌘T) – right-click: choose terminal app", TerminalChooser.shared.effectiveName)
    }

    @objc func revealInFinder(_ sender: Any?) {
        let urls = selectedURLs
        NSWorkspace.shared.activateFileViewerSelecting(urls.isEmpty ? [currentDir] : urls)
    }

    // MARK: Kopieren / Ausschneiden / Einfügen

    @objc func copy(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty else { NSSound.beep(); return }
        FileClipboard.write(urls, cut: false)
        flashStatus(L("%ld items copied", urls.count))
    }

    @objc func cut(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty else { NSSound.beep(); return }
        FileClipboard.write(urls, cut: true)
    }

    @objc func paste(_ sender: Any?) {
        pasteFiles(into: currentDir)
    }

    @objc func pasteIntoSelectedFolder(_ sender: Any?) {
        guard selectedItems.count == 1, selectedItems[0].isFolder else { return }
        pasteFiles(into: selectedItems[0].url)
    }

    private func pasteFiles(into dest: URL) {
        let urls = FileClipboard.read()
        guard !urls.isEmpty else { NSSound.beep(); return }
        let move = FileClipboard.isCutActive
        if move { FileClipboard.clearCut() }
        performTransfer(urls, to: dest, move: move)
    }

    @objc func copyPath(_ sender: Any?) { copyPaths(quoted: false) }
    @objc func copyPathQuoted(_ sender: Any?) { copyPaths(quoted: true) }

    @objc func copyName(_ sender: Any?) {
        let names = selectedItems.map(\.name)
        guard !names.isEmpty else { return }
        setPasteboardString(names.joined(separator: "\n"))
        flashStatus(L("Name copied: %@", names.joined(separator: ", ")))
    }

    @objc func copyCurrentFolderPath(_ sender: Any?) {
        setPasteboardString(currentDir.path)
        flashStatus(L("Path copied: %@", currentDir.path))
    }

    private func copyPaths(quoted: Bool) {
        var urls = selectedURLs
        if urls.isEmpty { urls = [currentDir] }
        let s = urls.map { quoted ? "\"\($0.path)\"" : $0.path }.joined(separator: "\n")
        setPasteboardString(s)
        flashStatus(urls.count == 1 ? L("Path copied: %@", s) : L("%ld paths copied", urls.count))
    }

    private func setPasteboardString(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
        FileClipboard.clearCut()
    }

    private func askConflict(_ name: String, multiple: Bool) -> (ConflictChoice, Bool) {
        let a = NSAlert()
        a.messageText = L("An item named “%@” already exists at the destination.", name)
        a.informativeText = L("Do you want to replace it, keep both, or skip this item?")
        a.addButton(withTitle: L("Replace"))
        a.addButton(withTitle: L("Keep Both"))
        a.addButton(withTitle: L("Skip"))
        if multiple {
            a.showsSuppressionButton = true
            a.suppressionButton?.title = L("Apply to all remaining conflicts")
        }
        let r = a.runModal()
        let c: ConflictChoice = r == .alertFirstButtonReturn ? .replace : (r == .alertSecondButtonReturn ? .keepBoth : .skip)
        return (c, a.suppressionButton?.state == .on)
    }

    func performTransfer(_ sources: [URL], to dest: URL, move: Bool) {
        let fm = FileManager.default
        let destPath = FileOps.canonical(dest)
        var jobs: [(src: URL, dst: URL, replace: Bool)] = []
        var applyAll: ConflictChoice?

        for src in sources {
            let srcPath = FileOps.canonical(src)
            guard fm.fileExists(atPath: src.path) else { continue }
            if destPath == srcPath || destPath.hasPrefix(srcPath + "/") {
                showError(L("“%@” cannot be copied or moved into itself.", src.lastPathComponent))
                continue
            }
            let isDir = FileOps.isDir(src)
            var target = dest.appendingPathComponent(src.lastPathComponent)
            if FileOps.canonical(src.deletingLastPathComponent()) == destPath {
                if move { continue }                     // Ausschneiden + Einfügen im selben Ordner
                target = FileOps.unique(in: dest, name: src.lastPathComponent, isDir: isDir, copySuffix: true)
                jobs.append((src, target, false))
                continue
            }
            if fm.fileExists(atPath: target.path) {
                let choice: ConflictChoice
                if let all = applyAll {
                    choice = all
                } else {
                    let (c, forAll) = askConflict(src.lastPathComponent, multiple: sources.count > 1)
                    choice = c
                    if forAll { applyAll = c }
                }
                switch choice {
                case .skip: continue
                case .keepBoth:
                    target = FileOps.unique(in: dest, name: src.lastPathComponent, isDir: isDir, copySuffix: true)
                    jobs.append((src, target, false))
                case .replace:
                    jobs.append((src, target, true))
                }
            } else {
                jobs.append((src, target, false))
            }
        }
        guard !jobs.isEmpty else { return }

        setBusy(true, move ? L("Moving %ld items…", jobs.count) : L("Copying %ld items…", jobs.count))
        let work = jobs
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fm = FileManager()
            var errors: [String] = []
            var done: [URL] = []
            for job in work {
                do {
                    if job.replace {
                        do { try fm.trashItem(at: job.dst, resultingItemURL: nil) }
                        catch { try fm.removeItem(at: job.dst) }
                    }
                    if move { try fm.moveItem(at: job.src, to: job.dst) }
                    else { try fm.copyItem(at: job.src, to: job.dst) }
                    done.append(job.dst)
                } catch {
                    errors.append("• \(job.src.lastPathComponent): \(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.setBusy(false, nil)
                FolderSizer.shared.invalidate(around: [dest] + (move ? sources : []))
                if FileOps.canonical(self.currentDir) == destPath { self.reloadItems(select: done) } else { self.reloadItems(select: nil) }
                if !errors.isEmpty { self.showError(L("Some items could not be transferred:") + "\n" + errors.joined(separator: "\n")) }
            }
        }
    }

    private func setBusy(_ busy: Bool, _ text: String?) {
        busyCount += busy ? 1 : -1
        busyCount = max(0, busyCount)
        if busyCount > 0 {
            spinner.startAnimation(nil)
            if let t = text { statusLabel.stringValue = t }
        } else {
            spinner.stopAnimation(nil)
            updateStatus()
        }
    }

    // MARK: Löschen / Umbenennen / Neu

    @objc func trashSelection() {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        let nextRow = table.selectedRowIndexes.first ?? 0
        NSWorkspace.shared.recycle(urls) { [weak self] _, err in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let err = err { self.showError(err.localizedDescription) }
                FolderSizer.shared.invalidate(around: urls)
                self.reloadItems(select: [])
                if !self.shown.isEmpty {
                    let r = min(nextRow, self.shown.count - 1)
                    self.table.selectRowIndexes([r], byExtendingSelection: false)
                    self.table.scrollRowToVisible(r)
                }
            }
        }
    }

    @objc func deletePermanently(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        let a = NSAlert()
        a.alertStyle = .critical
        a.messageText = urls.count == 1 ? L("Permanently delete “%@”?", urls[0].lastPathComponent)
                                         : L("Permanently delete %ld items?", urls.count)
        a.informativeText = L("This cannot be undone.")
        a.addButton(withTitle: L("Delete Permanently"))
        a.addButton(withTitle: L("Cancel"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        var errors: [String] = []
        for u in urls {
            do { try FileManager.default.removeItem(at: u) }
            catch { errors.append("• \(u.lastPathComponent): \(error.localizedDescription)") }
        }
        FolderSizer.shared.invalidate(around: urls)
        reloadItems(select: [])
        if !errors.isEmpty { showError(errors.joined(separator: "\n")) }
    }

    @objc func newFolder(_ sender: Any?) {
        if isDeepSearch { endDeepSearch() }
        window?.makeFirstResponder(table)
        let u = FileOps.unique(in: currentDir, name: L("New Folder"), isDir: true, copySuffix: false)
        do {
            try FileManager.default.createDirectory(at: u, withIntermediateDirectories: false)
            searchField.stringValue = ""
            reloadItems(select: [u])
            beginRename()
        } catch { showError(error.localizedDescription) }
    }

    @objc func newTextFile(_ sender: Any?) {
        if isDeepSearch { endDeepSearch() }
        window?.makeFirstResponder(table)
        let u = FileOps.unique(in: currentDir, name: L("New Text Document.txt"), isDir: false, copySuffix: false)
        if FileManager.default.createFile(atPath: u.path, contents: Data()) {
            searchField.stringValue = ""
            reloadItems(select: [u])
            beginRename()
        } else {
            showError(L("The file could not be created."))
        }
    }

    @objc func beginRename() {
        guard table.selectedRowIndexes.count == 1 else { return }
        let row = table.selectedRow
        let col = table.column(withIdentifier: .init("name"))
        guard row >= 0, col >= 0 else { return }
        table.scrollRowToVisible(row)
        guard let cell = table.view(atColumn: col, row: row, makeIfNecessary: true) as? NSTableCellView,
              let tf = cell.textField else { return }
        let item = shown[row]
        renamingURL = item.url
        cell.alphaValue = 1
        tf.isEditable = true
        tf.isSelectable = true
        tf.drawsBackground = true
        tf.backgroundColor = .textBackgroundColor
        window?.makeFirstResponder(tf)
        if let ed = tf.currentEditor() {
            let name = item.name as NSString
            let ext = item.isDirectory ? "" : name.pathExtension
            let len = ext.isEmpty ? name.length : name.length - (ext as NSString).length - 1
            ed.selectedRange = NSRange(location: 0, length: max(0, len))
        }
    }

    private func finishRename(_ tf: NSTextField, cancel: Bool) {
        guard let old = renamingURL else { return }
        renamingURL = nil
        tf.isEditable = false
        tf.isSelectable = false
        tf.drawsBackground = false
        let newName = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { window?.makeFirstResponder(table) }
        if cancel || newName.isEmpty || newName == old.lastPathComponent {
            tf.stringValue = old.lastPathComponent
            return
        }
        if newName.contains("/") || newName.contains(":") {
            tf.stringValue = old.lastPathComponent
            showError(L("File names cannot contain “/” or “:”."))
            return
        }
        let dst = old.deletingLastPathComponent().appendingPathComponent(newName)
        if FileManager.default.fileExists(atPath: dst.path) && newName.lowercased() != old.lastPathComponent.lowercased() {
            tf.stringValue = old.lastPathComponent
            showError(L("An item named “%@” already exists.", newName))
            return
        }
        do {
            try FileManager.default.moveItem(at: old, to: dst)
            FolderSizer.shared.invalidate(around: [old, dst])
            reloadItems(select: [dst])
        } catch {
            tf.stringValue = old.lastPathComponent
            showError(error.localizedDescription)
        }
    }

    // MARK: Schnellzugriff anheften

    @objc func pinSelected(_ sender: Any?) {
        let folders = selectedItems.filter(\.isFolder).map(\.url)
        pin(folders.isEmpty ? [currentDir] : folders)
    }

    /// ⌥⌘F: den aktuell angezeigten Ordner des aktiven Bereichs zu Favoriten.
    @objc func pinCurrent(_ sender: Any?) {
        if Favorites.shared.contains(currentDir) {
            flashStatus(L("“%@” is already a favorite", currentDir.lastPathComponent))
        } else {
            pin([currentDir])
        }
    }

    private func pin(_ urls: [URL]) {
        Favorites.shared.add(urls)
        flashStatus(urls.count == 1 ? L("“%@” added to favorites", urls[0].lastPathComponent)
                                    : L("%ld folders added to favorites", urls.count))
    }

    /// ⌃⌘T: markierte Ordner – oder, wenn keiner markiert ist, den aktuellen Ordner – zu Favoriten.
    @objc func addToFavorites(_ sender: Any?) { pinSelected(sender) }

    @objc func unpin(_ sender: NSMenuItem) {
        guard let u = sender.representedObject as? URL else { return }
        Favorites.shared.remove(u)
    }

    @objc func sidebarAddFavorite(_ sender: NSMenuItem) {
        if let u = sender.representedObject as? URL { pin([u]) }
    }

    @objc func sidebarOpenInNewTab(_ sender: NSMenuItem) {
        if let u = sender.representedObject as? URL { openInNewTab(u) }
    }

    @objc func sidebarCopyPath(_ sender: NSMenuItem) {
        if let u = sender.representedObject as? URL {
            setPasteboardString(u.path)
            flashStatus(L("Path copied: %@", u.path))
        }
    }

    // MARK: Quick Look

    func togglePreview() {
        guard let p = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && p.isVisible { p.orderOut(nil) }
        else { p.makeKeyAndOrderFront(nil) }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { selectedURLs.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        let urls = selectedURLs
        guard index < urls.count else { return nil }
        return urls[index] as NSURL
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        if event.type == .keyDown, [123, 124, 125, 126].contains(event.keyCode) {
            table.keyDown(with: event)
            return true
        }
        return false
    }

    // MARK: Fehler

    func showError(_ msg: String) {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = msg
        if let w = window, w.isVisible, w.attachedSheet == nil { a.beginSheetModal(for: w) }
        else { a.runModal() }
    }

    // MARK: NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === sidebar ? sidebarRows.count : shown.count
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier, image: Bool) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let tf = NSTextField(labelWithString: "")
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.lineBreakMode = .byTruncatingTail
        tf.font = .systemFont(ofSize: 13 * Zoom.factor)
        tf.cell?.isScrollable = false
        cell.addSubview(tf)
        cell.textField = tf
        if image {
            let iv = NSImageView()
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.imageScaling = .scaleProportionallyUpOrDown
            cell.addSubview(iv)
            cell.imageView = iv
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: Zoom.s(16)),
                iv.heightAnchor.constraint(equalToConstant: Zoom.s(16)),
                tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: Zoom.s(6)),
            ])
        } else {
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2).isActive = true
        }
        NSLayoutConstraint.activate([
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === sidebar { return sidebarView(row) }
        guard let col = tableColumn, row < shown.count else { return nil }
        let item = shown[row]
        let colID = col.identifier.rawValue
        let id = NSUserInterfaceItemIdentifier(colID + Zoom.suffix)
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView)
            ?? makeCell(id, image: colID == "name")
        guard let tf = cell.textField else { return cell }
        switch colID {
        case "name":
            tf.stringValue = item.name
            tf.delegate = self
            tf.isEditable = false
            tf.drawsBackground = false
            tf.textColor = .labelColor
            cell.imageView?.image = Icons.icon(for: item)
        case "date":
            tf.stringValue = cellText("date", item)
            tf.textColor = .secondaryLabelColor
        case "kind":
            tf.stringValue = cellText("kind", item)
            tf.textColor = .secondaryLabelColor
        case "folder":
            tf.stringValue = cellText("folder", item)
            tf.textColor = .secondaryLabelColor
            tf.lineBreakMode = .byTruncatingHead
            tf.toolTip = item.url.deletingLastPathComponent().path
        case "files":
            tf.stringValue = cellText("files", item)
            tf.textColor = .secondaryLabelColor
            tf.alignment = .right
        case "size":
            tf.stringValue = cellText("size", item)
            if item.isDirectory {
                let st = FolderSizer.shared.stats(item.url)
                tf.toolTip = st == nil ? L("Being calculated in the background")
                    : (st!.partial ? L("Some subfolders were not readable – at least this large.") : nil)
            } else {
                tf.toolTip = nil
            }
            tf.textColor = .secondaryLabelColor
            tf.alignment = .right
        default:
            break
        }
        cell.alphaValue = (FileClipboard.isCut(item.url) || item.hidden) ? 0.45 : 1
        return cell
    }

    private func sidebarView(_ row: Int) -> NSView? {
        switch sidebarRows[row] {
        case .header(let title):
            let id = NSUserInterfaceItemIdentifier("sbHeader" + Zoom.suffix)
            let cell = (sidebar.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? makeCell(id, image: false)
            cell.textField?.stringValue = title
            cell.textField?.font = .boldSystemFont(ofSize: 11 * Zoom.factor)
            cell.textField?.textColor = .secondaryLabelColor
            return cell
        case .hint(let text):
            let id = NSUserInterfaceItemIdentifier("sbHint" + Zoom.suffix)
            let cell = (sidebar.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? makeCell(id, image: false)
            cell.textField?.stringValue = text
            cell.textField?.font = .systemFont(ofSize: 11 * Zoom.factor)
            cell.textField?.textColor = .tertiaryLabelColor
            return cell
        case let .place(title, _, symbol, _):
            let id = NSUserInterfaceItemIdentifier("sbPlace" + Zoom.suffix)
            let cell = (sidebar.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? makeCell(id, image: true)
            cell.textField?.stringValue = title
            cell.imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            cell.imageView?.contentTintColor = .controlAccentColor
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard tableView === sidebar else { return false }
        if case .header = sidebarRows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard tableView === sidebar else { return true }
        if case .place = sidebarRows[row] { return true }
        return false
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tv = notification.object as? NSTableView else { return }
        if tv === sidebar {
            guard !suppressSidebarNav, sidebar.selectedRow >= 0,
                  let url = sidebarRows[sidebar.selectedRow].url else { return }
            navigate(to: url)
            window?.makeFirstResponder(table)
        } else {
            updateStatus()
            if QLPreviewPanel.sharedPreviewPanelExists(), let p = QLPreviewPanel.shared(), p.isVisible {
                p.reloadData()
            }
        }
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard tableView === table else { return }
        applyFilterAndSort(select: nil)
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        guard tableView === table, row < shown.count else { return nil }
        return shown[row].name
    }

    // Drag & Drop
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        if tableView === sidebar {
            // Nur Favoriten lassen sich ziehen (zum Umsortieren) – ohne Datei-URL, damit nichts kopiert wird
            guard let idx = favoriteIndex(ofRow: row) else { return nil }
            let item = NSPasteboardItem()
            item.setString(String(idx), forType: Favorites.dragType)
            return item
        }
        guard tableView === table, row < shown.count else { return nil }
        return shown[row].url as NSURL
    }

    /// Index in der Favoritenliste für eine Zeile der Seitenleiste.
    private func favoriteIndex(ofRow row: Int) -> Int? {
        guard row >= 0, row < sidebarRows.count, case let .place(_, url, _, true) = sidebarRows[row] else { return nil }
        return Favorites.shared.urls.firstIndex(of: url)
    }

    /// Erste Zeile nach der Kopfzeile „Favoriten“ und Anzahl der Favoriten-Zeilen.
    private var favoriteRowRange: (start: Int, count: Int) {
        var count = 0
        for r in sidebarRows.dropFirst() {
            if case .place(_, _, _, true) = r { count += 1 } else { break }
        }
        return (1, count)
    }

    private func validateSidebarDrop(_ info: NSDraggingInfo, row: Int) -> NSDragOperation {
        let (start, count) = favoriteRowRange
        let target = min(max(row, start), start + count)
        if info.draggingPasteboard.string(forType: Favorites.dragType) != nil {
            sidebar.setDropRow(target, dropOperation: .above)
            return .move
        }
        let folders = draggedURLs(info).filter { FileOps.isDir($0) && !NSWorkspace.shared.isFilePackage(atPath: $0.path) }
        guard !folders.isEmpty else { return [] }
        sidebar.setDropRow(target, dropOperation: .above)
        return info.draggingSourceOperationMask.contains(.copy) ? .copy : .generic
    }

    private func acceptSidebarDrop(_ info: NSDraggingInfo, row: Int) -> Bool {
        let start = favoriteRowRange.start
        if let s = info.draggingPasteboard.string(forType: Favorites.dragType), let from = Int(s) {
            Favorites.shared.move(from: from, to: row - start)
            return true
        }
        let folders = draggedURLs(info).filter { FileOps.isDir($0) && !NSWorkspace.shared.isFilePackage(atPath: $0.path) }
        guard !folders.isEmpty else { return false }
        Favorites.shared.add(folders, at: row - start)
        return true
    }

    private func draggedURLs(_ info: NSDraggingInfo) -> [URL] {
        let objs = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true]) ?? []
        return objs.compactMap { ($0 as? NSURL) as URL? }
    }

    private func dropTarget(row: Int, op: NSTableView.DropOperation) -> URL {
        if op == .on, row >= 0, row < shown.count, shown[row].isFolder { return shown[row].url }
        return currentDir
    }

    private func dragOperation(_ info: NSDraggingInfo, urls: [URL], target: URL) -> NSDragOperation {
        let mask = info.draggingSourceOperationMask
        if mask == .copy { return .copy }                              // ⌥ gedrückt
        if mask == .generic || mask == .move { return .move }          // ⌘ gedrückt
        let sameVolume = urls.first.flatMap(FileOps.volumeID).map { $0.isEqual(FileOps.volumeID(target)) } ?? false
        if sameVolume && mask.contains(.move) { return .move }
        return mask.contains(.copy) ? .copy : .move
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        if tableView === sidebar { return validateSidebarDrop(info, row: row) }
        guard tableView === table else { return [] }
        let urls = draggedURLs(info)
        guard !urls.isEmpty else { return [] }
        let target = dropTarget(row: row, op: dropOperation)
        if target == currentDir { tableView.setDropRow(-1, dropOperation: .on) }
        let t = FileOps.canonical(target)
        if urls.contains(where: { FileOps.canonical($0) == t }) { return [] }
        if urls.allSatisfy({ FileOps.canonical($0.deletingLastPathComponent()) == t }) { return [] }
        return dragOperation(info, urls: urls, target: target)
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        if tableView === sidebar { return acceptSidebarDrop(info, row: row) }
        let urls = draggedURLs(info)
        guard !urls.isEmpty else { return false }
        let target = dropTarget(row: row, op: dropOperation)
        let op = dragOperation(info, urls: urls, target: target)
        performTransfer(urls, to: target, move: op == .move)
        return true
    }

    // MARK: Textfelder (Adressleiste, Suche, Umbenennen)

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if control === addressField {
            if sel == #selector(NSResponder.insertNewline(_:)) { goToAddress(); return true }
            if sel == #selector(NSResponder.cancelOperation(_:)) {
                addressField.stringValue = currentDir.path
                window?.makeFirstResponder(table)
                return true
            }
            return false
        }
        if control === searchField {
            let term = searchField.stringValue.trimmingCharacters(in: .whitespaces)
            if sel == #selector(NSResponder.insertNewline(_:)), !term.isEmpty, term != deepTerm || !isDeepSearch {
                startDeepSearch(term)
                return true
            }
            if sel == #selector(NSResponder.cancelOperation(_:)), isDeepSearch {
                endDeepSearch()
                return true
            }
            if sel == #selector(NSResponder.insertNewline(_:)) || sel == #selector(NSResponder.moveDown(_:)) {
                window?.makeFirstResponder(table)
                if table.selectedRow < 0, !shown.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
                return true
            }
            return false
        }
        if let tf = control as? NSTextField, let old = renamingURL,
           sel == #selector(NSResponder.cancelOperation(_:)) {
            renamingURL = nil
            tf.abortEditing()
            tf.stringValue = old.lastPathComponent
            tf.isEditable = false
            tf.isSelectable = false
            tf.drawsBackground = false
            window?.makeFirstResponder(table)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let tf = obj.object as? NSTextField else { return }
        if tf === addressField {
            if window?.firstResponder !== addressField.currentEditor() { addressField.stringValue = currentDir.path }
            return
        }
        if tf !== searchField, renamingURL != nil { finishRename(tf, cancel: false) }
    }

    // MARK: Kontextmenüs

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu === sidebarMenu { buildSidebarMenu(menu); return }

        let row = table.clickedRow
        if row >= 0 && !table.selectedRowIndexes.contains(row) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        } else if row < 0 {
            table.deselectAll(nil)
        }
        let sel = selectedItems

        @discardableResult
        func add(_ title: String, _ action: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = []) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = self
            menu.addItem(i)
            return i
        }
        let sep = { menu.addItem(.separator()) }

        if sel.isEmpty {
            add(L("Paste"), #selector(paste(_:)), "v", [.control])
            sep()
            add(L("New Folder"), #selector(newFolder(_:)), "n", [.control, .shift])
            add(L("New Text File"), #selector(newTextFile(_:)))
            sep()
            add(L("Copy path of this folder"), #selector(copyCurrentFolderPath(_:)), "c", [.control, .shift])
            add(L("Open in Terminal"), #selector(openTerminal(_:)))
            add(L("Show in Finder"), #selector(revealInFinder(_:)))
            add(L("Add This Folder to Favorites"), #selector(pinCurrent(_:)), "f", [.command, .option])
            sep()
            let h = add(L("Show Hidden Files"), #selector(toggleHidden(_:)), "h", [.control])
            h.state = showHidden ? .on : .off
            add(L("Refresh"), #selector(reload))
            return
        }

        add(L("Open"), #selector(openSelection))
        let single = sel.count == 1 ? sel[0] : nil
        if isDeepSearch, single != nil { add(L("Open Enclosing Folder"), #selector(openContainingFolder(_:))) }
        if let it = single, it.isFolder {
            add(L("Open in New Tab"), #selector(openSelectedInNewTab(_:)))
            add(L("Open in New Window"), #selector(openSelectedInNewWindow(_:)))
            add(L("Open in Terminal"), #selector(openTerminal(_:)))
        }
        if let it = single, !it.isFolder {
            let apps = NSWorkspace.shared.urlsForApplications(toOpen: it.url)
            if !apps.isEmpty {
                let sub = NSMenu()
                for app in apps.prefix(20) {
                    let mi = NSMenuItem(title: FileManager.default.displayName(atPath: app.path),
                                        action: #selector(openWith(_:)), keyEquivalent: "")
                    mi.target = self
                    mi.representedObject = app
                    let ic = NSWorkspace.shared.icon(forFile: app.path)
                    ic.size = NSSize(width: 16, height: 16)
                    mi.image = ic
                    sub.addItem(mi)
                }
                let holder = NSMenuItem(title: L("Open With"), action: nil, keyEquivalent: "")
                holder.submenu = sub
                menu.addItem(holder)
            }
        }
        sep()
        add(L("Cut"), #selector(cut(_:)), "x", [.control])
        add(L("Copy"), #selector(copy(_:)), "c", [.control])
        if let it = single, it.isFolder, FileClipboard.hasFiles {
            add(L("Paste into This Folder"), #selector(pasteIntoSelectedFolder(_:)))
        }
        sep()
        add(L("Copy Path"), #selector(copyPath(_:)), "c", [.control, .shift])
        add(L("Copy as Path (with Quotes)"), #selector(copyPathQuoted(_:)))
        add(L("Copy Name"), #selector(copyName(_:)))
        sep()
        if single != nil { add(L("Rename"), #selector(beginRename)) }
        add(L("Move to Trash"), #selector(trashSelection))
        sep()
        add(L("Show in Finder"), #selector(revealInFinder(_:)))
        if sel.contains(where: { $0.isFolder }) { add(L("Add to Favorites"), #selector(pinSelected(_:)), "t", [.control, .command]) }
    }

    private func buildSidebarMenu(_ menu: NSMenu) {
        let row = sidebar.clickedRow
        guard row >= 0, case let .place(_, url, _, pinned) = sidebarRows[row] else { return }
        let open = NSMenuItem(title: L("Open in New Tab"), action: #selector(sidebarOpenInNewTab(_:)), keyEquivalent: "")
        open.target = self; open.representedObject = url
        menu.addItem(open)
        let cp = NSMenuItem(title: L("Copy Path"), action: #selector(sidebarCopyPath(_:)), keyEquivalent: "")
        cp.target = self; cp.representedObject = url
        menu.addItem(cp)
        if !pinned, !Favorites.shared.contains(url) {
            let fav = NSMenuItem(title: L("Add to Favorites"), action: #selector(sidebarAddFavorite(_:)), keyEquivalent: "")
            fav.target = self; fav.representedObject = url
            menu.addItem(fav)
        }
        if pinned {
            let un = NSMenuItem(title: L("Remove from Favorites"), action: #selector(unpin(_:)), keyEquivalent: "")
            un.target = self; un.representedObject = url
            menu.addItem(un)
        }
    }

    // MARK: Menü-Validierung

    private var isEditingText: Bool { window?.firstResponder is NSText }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let action = item.action else { return true }
        let hasSel = !selectedItems.isEmpty
        switch action {
        case #selector(copy(_:)), #selector(cut(_:)), #selector(copyName(_:)), #selector(copyPathQuoted(_:)):
            return hasSel
        case #selector(paste(_:)):
            return FileClipboard.hasFiles
        case #selector(trashSelection), #selector(openSelection), #selector(goUp):
            return !isEditingText && (action == #selector(goUp) ? currentDir.path != "/" : hasSel)
        case #selector(beginRename):
            return !isEditingText && selectedItems.count == 1
        case #selector(goBack):
            return !isEditingText && !backStack.isEmpty
        case #selector(goForward):
            return !isEditingText && !forwardStack.isEmpty
        case #selector(toggleCockpit(_:)):
            item.state = UserDefaults.standard.bool(forKey: cockpitDefaultsKey) ? .off : .on
            return true
        case #selector(toggleFavoritesSidebar(_:)):
            item.state = sidebarScroll.isHidden ? .off : .on
            return true
        case #selector(toggleHidden(_:)):
            item.state = showHidden ? .on : .off
            return true
        default:
            return true
        }
    }

    // MARK: Fenster

    // MARK: Seitenleiste ein-/ausklappen

    /// ⌃⌘S: Seitenleiste (Favoriten, Schnellzugriff, Laufwerke) dieses Bereichs ein- oder ausblenden.
    @objc func toggleFavoritesSidebar(_ sender: Any?) {
        UserDefaults.standard.set(!sidebarScroll.isHidden, forKey: sidebarDefaultsKey)
        applySidebarVisibility()
    }

    private func applySidebarVisibility() {
        guard let sb = sidebarScroll else { return }
        let hide = UserDefaults.standard.bool(forKey: sidebarDefaultsKey)
        guard hide != sb.isHidden else { return }
        if hide {
            if sb.frame.width > 60 { sidebarWidthBeforeHide = sb.frame.width }
            if let fr = window?.firstResponder as? NSView, fr.isDescendant(of: sb) { window?.makeFirstResponder(table) }
            sidebarMinWidth.isActive = false
            sb.isHidden = true
        } else {
            sb.isHidden = false
            sidebarMinWidth.isActive = true
            split.layoutSubtreeIfNeeded()
            split.setPosition(min(sidebarWidthBeforeHide, max(140, split.bounds.width * 0.4)), ofDividerAt: 0)
        }
        split.adjustSubviews()
        sidebarBtn.contentTintColor = hide ? .secondaryLabelColor : nil
        scheduleFitColumns(force: true)
    }

    /// Hintergrundfarbe dieses Bereichs (links/rechts) aus den Einstellungen.
    func applyPaneColor() {
        let c = PaneColors.color(side)
        table.backgroundColor = c ?? .controlBackgroundColor
        view.wantsLayer = true
        view.layer?.backgroundColor = c?.cgColor
        table.enclosingScrollView?.backgroundColor = c ?? .controlBackgroundColor
        table.needsDisplay = true
        // Seitenleiste: Source-List-Stil zeichnet einen eigenen Hintergrund → Farbe direkt setzen
        if sidebarDefaultBackground == nil { sidebarDefaultBackground = sidebar.backgroundColor }
        sidebar.backgroundColor = c ?? sidebarDefaultBackground ?? .clear
        sidebarScroll?.drawsBackground = c != nil
        if let c = c { sidebarScroll?.backgroundColor = c }
        sidebar.needsDisplay = true
    }

    private func updateHeader() {
        headerLabel.stringValue = sideName
        let color: NSColor = isActivePane ? .controlAccentColor : .tertiaryLabelColor
        headerLabel.textColor = isActivePane ? .labelColor : .secondaryLabelColor
        headerDot.contentTintColor = color
    }

    func windowDidBecomeKey() {
        refreshVisibleCells()
    }

    /// Fokus in die Dateiliste; ist nichts markiert, wird der erste Eintrag markiert.
    func focusList() {
        window?.makeFirstResponder(table)
        if table.selectedRow < 0, !shown.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
        }
        if table.selectedRow >= 0 { table.scrollRowToVisible(table.selectedRow) }
    }

    @discardableResult
    func focusOtherPane() -> Bool {
        guard let ew = explorerWindow, let other = ew.panes.first(where: { $0 !== self && !$0.view.isHidden }) else { return false }
        window?.makeFirstResponder(other.table)
        return true
    }

    @objc func toggleSplitFromPane(_ sender: Any?) {
        explorerWindow?.toggleSplit(sender)
    }

    func teardown() {
        FolderSizer.shared.cancel(owner: self)
        stopDeepQuery()
        watcher.stop()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
    }
}

// MARK: - Fenster

final class ExplorerWindow: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    private(set) var panes: [ExplorerController] = []
    private(set) weak var activePane: ExplorerController? { didSet { updateHeaders() } }
    private let paneSplit = NSSplitView()
    private var responderObs: NSKeyValueObservation?
    private var paneRatio: CGFloat = 0.5          // Anteil des linken Bereichs, bleibt beim Größenändern erhalten
    private var ratioConstraint: NSLayoutConstraint?
    var onClose: (() -> Void)?

    enum Layout { case left, right, both }
    private(set) var layout: Layout = .left
    var isSplit: Bool { layout == .both }
    private var visiblePanes: [ExplorerController] { panes.filter { !$0.view.isHidden } }

    init(dir: URL) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.minSize = NSSize(width: 640, height: 360)
        w.isReleasedWhenClosed = false
        w.tabbingMode = .automatic
        w.tabbingIdentifier = "ExplorerWindow"
        super.init(window: w)
        w.delegate = self
        paneSplit.isVertical = true
        paneSplit.dividerStyle = .thick
        w.contentView = paneSplit
        addPane(dir: dir, width: 1100)
        updateTitle()
        let nc = NotificationCenter.default
        paneSplit.postsFrameChangedNotifications = true
        nc.addObserver(forName: NSSplitView.didResizeSubviewsNotification, object: paneSplit, queue: .main) { [weak self] n in
            // Nur wenn der Trenner von Hand gezogen wurde, das neue Verhältnis übernehmen
            guard let self = self, self.isSplit, n.userInfo?["NSSplitViewDividerIndex"] != nil,
                  NSEvent.pressedMouseButtons & 1 != 0,          // nur echtes Ziehen mit der Maus
                  self.paneSplit.bounds.width > 0 else { return }
            self.paneRatio = min(0.85, max(0.15, self.panes[0].view.frame.width / self.paneSplit.bounds.width))
            self.keepPaneRatio()
        }
        responderObs = w.observe(\.firstResponder, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.firstResponderChanged() }
        }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    @discardableResult
    private func addPane(dir: URL, width: CGFloat) -> ExplorerController {
        let p = ExplorerController(dir: dir, width: width)
        panes.append(p)
        p.side = panes.count == 1 ? 0 : 1
        paneSplit.addArrangedSubview(p.view)
        // Trennerposition hat Vorrang vor Inhaltswünschen (Suchfeld, Adressleiste …), sonst „springt“ die Aufteilung
        paneSplit.setHoldingPriority(NSLayoutConstraint.Priority(200), forSubviewAt: panes.count - 1)
        if activePane == nil { activePane = p }
        return p
    }

    /// Nur links, nur rechts oder beide Bereiche. Ausgeblendete Bereiche bleiben erhalten
    /// (Ordner, Verlauf, Auswahl) und erscheinen beim Wiedereinblenden unverändert.
    func setLayout(_ new: Layout) {
        guard let w = window else { return }
        if new == layout { activePane?.focusList(); return }
        let wasSingle = layout != .both
        if panes.count < 2 {
            let dir = activePane?.currentDir ?? FileManager.default.homeDirectoryForCurrentUser
            let p = addPane(dir: dir, width: max(paneSplit.bounds.width / 2, 480))
            p.view.isHidden = true
        }
        let left = panes[0], right = panes[1]

        if new == .both && wasSingle, !w.styleMask.contains(.fullScreen),
           let screen = w.screen?.visibleFrame, w.frame.width < 1400 {
            // Fenster verbreitern, damit beide Bereiche Platz haben (nicht im Vollbild)
            var f = w.frame
            f.size.width = min(max(f.width * 2, 1400), screen.width)
            if f.maxX > screen.maxX { f.origin.x = max(screen.minX, screen.maxX - f.width) }
            w.setFrame(f, display: true, animate: false)
        }
        left.view.isHidden = new == .right
        right.view.isHidden = new == .left
        layout = new
        keepPaneRatio()
        w.minSize = NSSize(width: new == .both ? 960 : 640, height: 360)
        paneSplit.adjustSubviews()
        paneSplit.layoutSubtreeIfNeeded()
        if new == .both && wasSingle {
            paneRatio = 0.5
            keepPaneRatio(now: true)
        }

        let focus: ExplorerController
        switch new {
        case .left: focus = left
        case .right: focus = right
        case .both: focus = activePane ?? left
        }
        activePane = focus
        focus.focusList()
        updateTitle()
    }

    /// Fokus in den linken (0) oder rechten (1) Bereich, sofern sichtbar.
    func focusPane(_ index: Int) {
        guard index < panes.count, !panes[index].view.isHidden else { NSSound.beep(); return }
        activePane = panes[index]
        panes[index].focusList()
        updateTitle()
    }

    @objc func focusLeftPane(_ sender: Any?) { focusPane(0) }
    @objc func focusRightPane(_ sender: Any?) { focusPane(1) }

    @objc func showLeftOnly(_ sender: Any?) { setLayout(.left) }
    @objc func showRightOnly(_ sender: Any?) { setLayout(.right) }
    @objc func showBoth(_ sender: Any?) { setLayout(.both) }

    /// Beide ⇄ nur der aktive Bereich.
    @objc func toggleSplit(_ sender: Any?) {
        if layout == .both {
            setLayout(activePane === panes.last && panes.count > 1 ? .right : .left)
        } else {
            setLayout(.both)
        }
    }

    /// Linken Bereich per Layout-Bedingung auf `paneRatio` der Gesamtbreite halten. Die Bedingung
    /// (Priorität 300) schlägt die Haltebreite des Split-Views (200), verliert aber gegen das Ziehen
    /// mit der Maus; danach wird der Anteil übernommen.
    private func keepPaneRatio(now: Bool = false) {
        ratioConstraint?.isActive = false
        ratioConstraint = nil
        guard isSplit, panes.count > 1 else { return }
        let half = paneSplit.dividerThickness / 2
        let c = panes[0].view.widthAnchor.constraint(equalTo: paneSplit.widthAnchor, multiplier: paneRatio, constant: -half)
        c.priority = NSLayoutConstraint.Priority(300)
        c.isActive = true
        ratioConstraint = c
        if now { paneSplit.layoutSubtreeIfNeeded() }
    }

    private func firstResponderChanged() {
        guard let fr = window?.firstResponder else { return }
        var view = fr as? NSView
        if let text = fr as? NSText, let owner = text.delegate as? NSView { view = owner }
        guard let v = view, let p = panes.first(where: { v.isDescendant(of: $0.view) }), p !== activePane else { return }
        activePane = p
        updateTitle()
    }

    private func updateHeaders() {
        for p in panes { p.isActivePane = p === activePane }
    }

    func updateTitle() {
        guard let w = window, let p = activePane ?? panes.first else { return }
        let fm = FileManager.default
        if isSplit {
            w.title = visiblePanes.map { fm.displayName(atPath: $0.currentDir.path) }.joined(separator: "  |  ")
        } else {
            w.title = fm.displayName(atPath: p.currentDir.path) + (panes.count > 1 ? "  –  \(p.sideName)" : "")
        }
        w.representedURL = p.currentDir
    }

    // Menübefehle, die das Fenster selbst erreichen, an den aktiven Bereich weitergeben
    override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
        if let p = activePane, p.responds(to: action) { return p }
        return super.supplementalTarget(forAction: action, sender: sender)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleSplit(_:)), #selector(showBoth(_:)): item.state = layout == .both ? .on : .off
        case #selector(showLeftOnly(_:)): item.state = layout == .left ? .on : .off
        case #selector(showRightOnly(_:)): item.state = layout == .right ? .on : .off
        default: break
        }
        return true
    }

    // Nach Vollbild ein/aus: Fokus zurück in die Dateiliste des aktiven Bereichs
    func windowDidEnterFullScreen(_ notification: Notification) { (activePane ?? panes.first)?.focusList() }
    func windowDidExitFullScreen(_ notification: Notification) { (activePane ?? panes.first)?.focusList() }

    func windowDidBecomeKey(_ notification: Notification) {
        panes.forEach { $0.windowDidBecomeKey() }
    }

    func windowWillClose(_ notification: Notification) {
        responderObs = nil
        panes.forEach { $0.teardown() }
        onClose?()
    }
}

// MARK: - App

// MARK: - Terminal-Auswahl

/// Welche Terminal-App der Terminal-Button öffnet. Gespeichert unter "terminalBundleID"
/// (nil = automatisch: iTerm2, sonst Terminal).
final class TerminalChooser: NSObject, NSMenuDelegate {
    static let shared = TerminalChooser()

    private enum Launch { case openFolder, args((String) -> [String]) }
    private struct Known { let name: String; let id: String; let launch: Launch }

    // Terminals, die beim Öffnen eines Ordners nicht dorthin wechseln, bekommen das Verzeichnis als Argument.
    private let known: [Known] = [
        Known(name: "Terminal", id: "com.apple.Terminal", launch: .openFolder),
        Known(name: "iTerm2", id: "com.googlecode.iterm2", launch: .openFolder),
        Known(name: "Warp", id: "dev.warp.Warp-Stable", launch: .openFolder),
        Known(name: "Ghostty", id: "com.mitchellh.ghostty", launch: .openFolder),
        Known(name: "Alacritty", id: "org.alacritty", launch: .args { ["--working-directory", $0] }),
        Known(name: "kitty", id: "net.kovidgoyal.kitty", launch: .args { ["--directory", $0] }),
        Known(name: "WezTerm", id: "com.github.wez.wezterm", launch: .args { ["start", "--cwd", $0] }),
        Known(name: "Hyper", id: "co.zeit.hyper", launch: .openFolder),
        Known(name: "Tabby", id: "org.tabby", launch: .openFolder),
    ]
    private let defaultsKey = "terminalBundleID"

    var preferredID: String? {
        get { UserDefaults.standard.string(forKey: defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    private func appURL(_ id: String) -> URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) }

    private func displayName(_ id: String) -> String {
        if let k = known.first(where: { $0.id == id }) { return k.name }
        if let url = appURL(id) { return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "") }
        return id
    }

    /// Name der Terminal-App, die tatsächlich geöffnet wird.
    var effectiveName: String {
        let auto = ["com.googlecode.iterm2", "com.apple.Terminal"]
        let ids = (preferredID.map { [$0] } ?? []) + auto
        return ids.first(where: { appURL($0) != nil }).map(displayName) ?? "Terminal"
    }

    func open(_ dir: URL) {
        let auto = ["com.googlecode.iterm2", "com.apple.Terminal"]
        for id in (preferredID.map { [$0] } ?? []) + auto {
            guard let app = appURL(id) else { continue }
            let config = NSWorkspace.OpenConfiguration()
            let launch = known.first(where: { $0.id == id })?.launch ?? .openFolder
            switch launch {
            case .openFolder:
                NSWorkspace.shared.open([dir], withApplicationAt: app, configuration: config) { _, err in
                    if let err = err { DispatchQueue.main.async { NSApp.presentError(err) } }
                }
            case .args(let make):
                config.arguments = make(dir.path)
                config.createsNewApplicationInstance = true
                NSWorkspace.shared.openApplication(at: app, configuration: config) { _, err in
                    if let err = err { DispatchQueue.main.async { NSApp.presentError(err) } }
                }
            }
            return
        }
        NSSound.beep()
    }

    // MARK: Menü

    func makeMenu() -> NSMenu {
        let m = NSMenu(title: L("Terminal App"))
        m.delegate = self
        menuNeedsUpdate(m)
        return m
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ id: String?, icon: URL? = nil) {
            let i = NSMenuItem(title: title, action: #selector(choose(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = id
            i.state = preferredID == id ? .on : .off
            if let icon = icon {
                let img = NSWorkspace.shared.icon(forFile: icon.path)
                img.size = NSSize(width: 16, height: 16)
                i.image = img
            }
            menu.addItem(i)
        }
        add(L("Automatic (iTerm2, otherwise Terminal)"), nil)
        menu.addItem(.separator())
        for k in known { if let url = appURL(k.id) { add(k.name, k.id, icon: url) } }
        if let id = preferredID, !known.contains(where: { $0.id == id }), let url = appURL(id) {
            add(displayName(id), id, icon: url)
        }
        menu.addItem(.separator())
        let other = NSMenuItem(title: L("Choose Other App…"), action: #selector(chooseOther(_:)), keyEquivalent: "")
        other.target = self
        menu.addItem(other)
    }

    @objc private func choose(_ sender: NSMenuItem) {
        preferredID = sender.representedObject as? String
        NotificationCenter.default.post(name: .terminalChoiceChanged, object: nil)
    }

    @objc private func chooseOther(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = L("Choose Terminal App")
        panel.prompt = L("Choose")
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let id = Bundle(url: url)?.bundleIdentifier else { NSSound.beep(); return }
        preferredID = id
        NotificationCenter.default.post(name: .terminalChoiceChanged, object: nil)
    }
}

extension Notification.Name {
    static let terminalChoiceChanged = Notification.Name("terminalChoiceChanged")
}

// MARK: - Einstellungen

enum StartPrefs {
    enum WindowMode: String, CaseIterable { case normal, maximized, fullscreen }
    enum Panes: String, CaseIterable { case left, both }

    static var windowMode: WindowMode {
        get { WindowMode(rawValue: UserDefaults.standard.string(forKey: "startWindowMode") ?? "") ?? .normal }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "startWindowMode") }
    }
    static var panes: Panes {
        get { Panes(rawValue: UserDefaults.standard.string(forKey: "startPanes") ?? "") ?? .left }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "startPanes") }
    }
}

extension Notification.Name {
    static let paneColorsChanged = Notification.Name("ExplorerPaneColorsChanged")
}

/// Hintergrundfarbe je Bereich (links = 0, rechts = 1). nil = Systemstandard.
enum PaneColors {
    private static func key(_ side: Int) -> String { side == 0 ? "paneColorLeft" : "paneColorRight" }

    static func color(_ side: Int) -> NSColor? {
        guard let hex = UserDefaults.standard.string(forKey: key(side)), hex.count == 9, hex.hasPrefix("#"),
              let v = UInt64(hex.dropFirst(), radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 24) & 0xFF) / 255, green: CGFloat((v >> 16) & 0xFF) / 255,
                       blue: CGFloat((v >> 8) & 0xFF) / 255, alpha: CGFloat(v & 0xFF) / 255)
    }

    static func set(_ side: Int, _ color: NSColor?) {
        if let c = color?.usingColorSpace(.sRGB) {
            let v = [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent]
                .map { String(format: "%02X", Int(($0 * 255).rounded())) }.joined()
            UserDefaults.standard.set("#" + v, forKey: key(side))
        } else {
            UserDefaults.standard.removeObject(forKey: key(side))
        }
        NotificationCenter.default.post(name: .paneColorsChanged, object: nil)
    }
}

final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    override func close() {
        colorWells.forEach { $0.deactivate() }
        super.close()
    }

    private let modePopup = NSPopUpButton()
    private let panesPopup = NSPopUpButton()
    private let modeTitles: [(StartPrefs.WindowMode, String)] = [
        (.normal, L("Normal window")), (.maximized, L("Maximized (whole screen, with menu bar)")),
        (.fullscreen, L("Full screen"))]
    private let panesTitles: [(StartPrefs.Panes, String)] = [
        (.left, L("Left Pane Only")), (.both, L("Both panes (left and right)"))]

    private init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 170),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = L("Settings")
        w.isReleasedWhenClosed = false
        super.init(window: w)

        modeTitles.forEach { modePopup.addItem(withTitle: $0.1) }
        panesTitles.forEach { panesPopup.addItem(withTitle: $0.1) }
        modePopup.target = self; modePopup.action = #selector(changed(_:))
        panesPopup.target = self; panesPopup.action = #selector(changed(_:))

        let heading = NSTextField(labelWithString: L("At Launch"))
        heading.font = .boldSystemFont(ofSize: 13)
        let note = NSTextField(labelWithString: L("Applies when a window opens and no other one is open yet\n(app launch, click on the Dock icon, ⌥⌘E)."))
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: L("Window:")), modePopup],
            [NSTextField(labelWithString: L("Panes:")), panesPopup],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline

        // Farben je Bereich
        let colorHeading = NSTextField(labelWithString: L("Background Color"))
        colorHeading.font = .boldSystemFont(ofSize: 13)
        for (i, well) in colorWells.enumerated() {
            well.target = self
            well.action = #selector(colorChanged(_:))
            well.tag = i
            well.translatesAutoresizingMaskIntoConstraints = false
            well.widthAnchor.constraint(equalToConstant: 44).isActive = true
            well.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }
        func resetButton(_ side: Int) -> NSButton {
            let b = NSButton(title: L("Default"), target: self, action: #selector(resetColor(_:)))
            b.tag = side
            b.bezelStyle = .rounded
            return b
        }
        let colorGrid = NSGridView(views: [
            [NSTextField(labelWithString: L("Left pane:")), colorWells[0], resetButton(0)],
            [NSTextField(labelWithString: L("Right pane:")), colorWells[1], resetButton(1)],
        ])
        colorGrid.rowSpacing = 10
        colorGrid.columnSpacing = 10
        colorGrid.column(at: 0).xPlacement = .trailing
        colorGrid.rowAlignment = .none
        for r in 0..<colorGrid.numberOfRows { colorGrid.row(at: r).yPlacement = .center }
        let colorNote = NSTextField(labelWithString: L("Colors the whole pane (file list, sidebar, bars). Takes effect immediately."))
        colorNote.font = .systemFont(ofSize: 11)
        colorNote.textColor = .secondaryLabelColor

        let sep = NSBox(); sep.boxType = .separator
        let stack = NSStackView(views: [heading, grid, note, sep, colorHeading, colorGrid, colorNote])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        w.contentView = stack
        w.setContentSize(NSSize(width: 520, height: stack.fittingSize.height))
    }

    private let colorWells = [NSColorWell(), NSColorWell()]

    @objc private func colorChanged(_ sender: NSColorWell) {
        PaneColors.set(sender.tag, sender.color)
    }

    @objc private func resetColor(_ sender: NSButton) {
        PaneColors.set(sender.tag, nil)
        colorWells[sender.tag].color = .controlBackgroundColor
        NSColorPanel.shared.orderOut(nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    @objc func show() {
        for i in 0..<2 { colorWells[i].color = PaneColors.color(i) ?? .controlBackgroundColor }
        modePopup.selectItem(at: modeTitles.firstIndex { $0.0 == StartPrefs.windowMode } ?? 0)
        panesPopup.selectItem(at: panesTitles.firstIndex { $0.0 == StartPrefs.panes } ?? 0)
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func changed(_ sender: NSPopUpButton) {
        if sender === modePopup { StartPrefs.windowMode = modeTitles[max(0, sender.indexOfSelectedItem)].0 }
        if sender === panesPopup { StartPrefs.panes = panesTitles[max(0, sender.indexOfSelectedItem)].0 }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controllers: [ExplorerWindow] = []
    private var keyMonitor: Any?
    private var lastPaneArrow: (key: CGKeyCode, time: Date)?

    var keyController: ExplorerController? {
        (NSApp.keyWindow?.windowController as? ExplorerWindow)?.activePane
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        installCtrlShortcuts()
        installGlobalHotKey()
        if controllers.isEmpty { openWindow(at: FileManager.default.homeDirectoryForCurrentUser) }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openWindow(at: FileManager.default.homeDirectoryForCurrentUser) }
        return true
    }

    // Ordner aufs Dock-Icon ziehen → öffnen
    func application(_ application: NSApplication, open urls: [URL]) {
        for u in urls {
            if FileOps.isDir(u) && !NSWorkspace.shared.isFilePackage(atPath: u.path) {
                openWindow(at: u)
            } else {
                openWindow(at: u.deletingLastPathComponent())
            }
        }
    }

    @discardableResult
    func openWindow(at url: URL, tabbedWith host: NSWindow? = nil) -> ExplorerWindow {
        // Erstes sichtbares Fenster (App-Start, Dock-Klick, ⌥⌘E ohne offene Fenster) → Startdarstellung anwenden
        let isFirst = host == nil && !controllers.contains { $0.window?.isVisible == true || $0.window?.isMiniaturized == true }
        let c = ExplorerWindow(dir: url)
        controllers.append(c)
        c.onClose = { [weak self, weak c] in self?.controllers.removeAll { $0 === c } }
        guard let w = c.window else { return c }
        if let host = host {
            host.addTabbedWindow(w, ordered: .above)
            w.makeKeyAndOrderFront(nil)
        } else {
            if let k = NSApp.keyWindow {
                w.setFrameTopLeftPoint(NSPoint(x: k.frame.minX + 28, y: k.frame.maxY - 28))
            } else {
                w.center()
            }
            c.showWindow(nil)
        }
        c.panes.first?.focusList()
        if isFirst { applyStartPrefs(c) }
        return c
    }

    /// Startdarstellung aus den Einstellungen auf das erste Fenster anwenden.
    private func applyStartPrefs(_ c: ExplorerWindow) {
        guard let w = c.window else { return }
        let mode = StartPrefs.windowMode
        if mode == .maximized, let screen = w.screen ?? NSScreen.main {
            w.setFrame(screen.visibleFrame, display: true)
        }
        if StartPrefs.panes == .both { c.setLayout(.both) }
        if mode == .fullscreen {
            DispatchQueue.main.async { if !w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) } }
        }
    }

    @objc func showSettings(_ sender: Any?) { SettingsWindowController.shared.show() }

    @objc func zoomIn(_ sender: Any?) { Zoom.zoomIn() }
    @objc func zoomOut(_ sender: Any?) { Zoom.zoomOut() }
    @objc func zoomReset(_ sender: Any?) { Zoom.reset() }

    @objc func newWindow(_ sender: Any?) {
        openWindow(at: keyController?.currentDir ?? FileManager.default.homeDirectoryForCurrentUser)
    }

    @objc func newTab(_ sender: Any?) {
        openWindow(at: keyController?.currentDir ?? FileManager.default.homeDirectoryForCurrentUser,
                   tabbedWith: NSApp.keyWindow)
    }

    // "+" in der Tab-Leiste
    @objc func newWindowForTab(_ sender: Any?) { newTab(sender) }

    // MARK: Globales Kürzel ⌥⌘E (wie Win+E) – öffnet von überall ein neues Skipper-Fenster

    private var hotKeyRef: EventHotKeyRef?

    private func installGlobalHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            DispatchQueue.main.async { (NSApp.delegate as? AppDelegate)?.globalHotKeyPressed() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x4558_504C), id: 1)   // 'EXPL'
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_E), UInt32(cmdKey | optionKey), id,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            NSLog("Skipper: global shortcut ⌥⌘E could not be registered (status \(status)) – possibly taken by another app.")
        } else {
            NSLog("Skipper: global shortcut ⌥⌘E registered.")
        }
    }

    /// Wie Win+E: öffnet immer ein neues Skipper-Fenster im Benutzerordner und holt es nach vorn.
    func globalHotKeyPressed() {
        NSApp.activate(ignoringOtherApps: true)
        let c = openWindow(at: FileManager.default.homeDirectoryForCurrentUser)
        c.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Strg-Kürzel wie unter Windows (zusätzlich zu ⌘)

    @objc func toggleFullScreenKey(_ sender: Any?) {
        (keyController?.window ?? NSApp.keyWindow)?.toggleFullScreen(nil)
    }

    private func installCtrlShortcuts() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [unowned self] event in
            let m = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.capsLock, .numericPad, .function])
            guard let ch = event.charactersIgnoringModifiers?.lowercased(), !ch.isEmpty else { return event }

            // ⌃⌥⌘← / ⌃⌥⌘→ → Fokus in den linken / rechten Bereich
            if m == [.control, .option, .command], event.keyCode == 123 || event.keyCode == 124,
               let ew = NSApp.keyWindow?.windowController as? ExplorerWindow {
                ew.focusPane(event.keyCode == 123 ? 0 : 1)
                return nil
            }
            // ⌥⌘← / ⌥⌘→ → nur linker / nur rechter Bereich; beide Pfeile zusammen → beide
            if m == [.command, .option], event.keyCode == 123 || event.keyCode == 124,
               let ew = NSApp.keyWindow?.windowController as? ExplorerWindow {
                let other: CGKeyCode = event.keyCode == 123 ? 124 : 123
                let now = Date()
                let otherHeld = CGEventSource.keyState(.combinedSessionState, key: other)
                let quickChord = self.lastPaneArrow.map { $0.key == other && now.timeIntervalSince($0.time) < 0.35 } ?? false
                self.lastPaneArrow = (CGKeyCode(event.keyCode), now)
                if otherHeld || quickChord { ew.setLayout(.both) }
                else { ew.setLayout(event.keyCode == 123 ? .left : .right) }
                return nil
            }
            // ⌥⌘↩ bzw. ⌥↩ → Vollbild ein/aus (funktioniert überall, auch in Text- und Suchfeld)
            if m == [.option] || m == [.command, .option], event.keyCode == 36 || event.keyCode == 76 {
                guard let w = NSApp.keyWindow, w.windowController is ExplorerWindow else { return event }
                w.toggleFullScreen(nil)
                return nil
            }
            // Alt+D → Adressleiste (wie Windows)
            if m == [.option], event.keyCode == 2 {
                return NSApp.sendAction(#selector(ExplorerController.focusAddress(_:)), to: nil, from: nil) ? nil : event
            }
            guard m.contains(.control), !m.contains(.command), !m.contains(.option) else { return event }
            let shift = m.contains(.shift)

            let sel: Selector?
            switch (ch, shift) {
            case ("c", false): sel = #selector(NSText.copy(_:))
            case ("x", false): sel = #selector(NSText.cut(_:))
            case ("v", false): sel = #selector(NSText.paste(_:))
            case ("a", false): sel = #selector(NSText.selectAll(_:))
            case ("c", true):  sel = #selector(ExplorerController.copyPath(_:))
            case ("n", true):  sel = #selector(ExplorerController.newFolder(_:))
            case ("n", false): sel = #selector(AppDelegate.newWindow(_:))
            case ("t", false): sel = #selector(AppDelegate.newTab(_:))
            case ("w", false): sel = #selector(NSWindow.performClose(_:))
            case ("l", false): sel = #selector(ExplorerController.focusAddress(_:))
            case ("f", false), ("e", false): sel = #selector(ExplorerController.focusSearch(_:))
            case ("h", false): sel = #selector(ExplorerController.toggleHidden(_:))
            case ("r", false): sel = #selector(ExplorerController.reload)
            default: sel = nil
            }
            guard let action = sel else { return event }
            // Strg+A in der Dateiliste → alle Dateien
            if action == #selector(NSText.selectAll(_:)), let t = NSApp.keyWindow?.firstResponder as? FileTableView {
                t.selectAll(nil)
                return nil
            }
            return NSApp.sendAction(action, to: nil, from: nil) ? nil : event
        }
    }

    // MARK: Hauptmenü (⌘-Kürzel)

    private func buildMainMenu() {
        let main = NSMenu()
        func item(_ title: String, _ action: Selector?, _ key: String = "",
                  _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            return i
        }
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let m = NSMenu(title: title)
            items.forEach { m.addItem($0) }
            top.submenu = m
            main.addItem(top)
            return m
        }
        let up = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        let down = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        let left = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
        let right = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
        let backspace = String(Character(UnicodeScalar(8)))

        _ = submenu("Skipper", [
            item(L("About Skipper"), #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            .separator(),
            item(L("Settings…"), #selector(AppDelegate.showSettings(_:)), ","),
            {
                let t = item(L("Terminal App"), nil)
                t.submenu = TerminalChooser.shared.makeMenu()
                return t
            }(),
            .separator(),
            item(L("Hide Skipper"), #selector(NSApplication.hide(_:)), "h"),
            item(L("Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            .separator(),
            item(L("Quit Skipper"), #selector(NSApplication.terminate(_:)), "q"),
        ])
        _ = submenu(L("File"), [
            item(L("New Window"), #selector(newWindow(_:)), "n"),
            item(L("New Tab"), #selector(newTab(_:)), "t"),
            item(L("New Folder"), #selector(ExplorerController.newFolder(_:)), "n", [.command, .option]),
            {   // ⌘⇧N wie im Finder funktioniert weiterhin (sichtbar bei gedrückter ⇧-Taste)
                let i = item(L("New Folder"), #selector(ExplorerController.newFolder(_:)), "n", [.command, .shift])
                i.isAlternate = true
                return i
            }(),
            item(L("New Text File"), #selector(ExplorerController.newTextFile(_:))),
            .separator(),
            item(L("Open"), #selector(ExplorerController.openSelection), down),
            item(L("Open in Terminal"), #selector(ExplorerController.openTerminal(_:)), "t", [.command, .option]),
            item(L("Show in Finder"), #selector(ExplorerController.revealInFinder(_:)), "r", [.command, .shift]),
            item(L("Add to Favorites"), #selector(ExplorerController.addToFavorites(_:)), "t", [.control, .command]),
            item(L("Add Current Folder to Favorites"), #selector(ExplorerController.pinCurrent(_:)), "f", [.command, .option]),
            .separator(),
            item(L("Close"), #selector(NSWindow.performClose(_:)), "w"),
        ])
        _ = submenu(L("Edit"), [
            item(L("Cut"), #selector(NSText.cut(_:)), "x"),
            item(L("Copy"), #selector(NSText.copy(_:)), "c"),
            item(L("Paste"), #selector(NSText.paste(_:)), "v"),
            item(L("Select All"), #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item(L("Copy Path"), #selector(ExplorerController.copyPath(_:)), "c", [.command, .option]),
            item(L("Copy as Path (with Quotes)"), #selector(ExplorerController.copyPathQuoted(_:))),
            item(L("Copy Name"), #selector(ExplorerController.copyName(_:))),
            .separator(),
            item(L("Rename"), #selector(ExplorerController.beginRename), ""),
            item(L("Move to Trash"), #selector(ExplorerController.trashSelection), backspace),
        ])
        _ = submenu(L("View"), [
            item(L("Show Hidden Files"), #selector(ExplorerController.toggleHidden(_:)), ".", [.command, .shift]),
            item(L("Refresh"), #selector(ExplorerController.reload), "r"),
            .separator(),
            item(L("Toggle Sidebar (Active Pane)"), #selector(ExplorerController.toggleFavoritesSidebar(_:)), "s", [.control, .command]),
            item(L("Toggle Folder Overview (Active Pane)"), #selector(ExplorerController.toggleCockpit(_:)), "i", [.control, .command]),
            item(L("Show Tab Bar"), #selector(NSWindow.toggleTabBar(_:)), ""),
            item(L("Zoom In"), #selector(AppDelegate.zoomIn(_:)), "+"),
            {   // US-Tastatur: ⌘= (ohne Umschalt) wie in VS Code
                let i = item(L("Zoom In"), #selector(AppDelegate.zoomIn(_:)), "=")
                i.isHidden = true
                i.allowsKeyEquivalentWhenHidden = true
                return i
            }(),
            item(L("Zoom Out"), #selector(AppDelegate.zoomOut(_:)), "-"),
            item(L("Actual Size"), #selector(AppDelegate.zoomReset(_:)), "0"),
            .separator(),
            item(L("Toggle Full Screen"), #selector(AppDelegate.toggleFullScreenKey(_:)), "\r", [.command, .option]),
            .separator(),
            item(L("Left Pane Only"), #selector(ExplorerWindow.showLeftOnly(_:)), left, [.command, .option]),
            item(L("Right Pane Only"), #selector(ExplorerWindow.showRightOnly(_:)), right, [.command, .option]),
            item(L("Both Panes (⌥⌘← + →)"), #selector(ExplorerWindow.showBoth(_:)), "s", [.command, .option]),
            .separator(),
            item(L("Focus: Left Pane"), #selector(ExplorerWindow.focusLeftPane(_:)), left, [.control, .option, .command]),
            item(L("Focus: Right Pane"), #selector(ExplorerWindow.focusRightPane(_:)), right, [.control, .option, .command]),
        ])
        _ = submenu(L("Go"), [
            item(L("Back"), #selector(ExplorerController.goBack), "["),
            item(L("Forward"), #selector(ExplorerController.goForward), "]"),
            item(L("Enclosing Folder"), #selector(ExplorerController.goUp), up),
            .separator(),
            item(L("Address Bar"), #selector(ExplorerController.focusAddress(_:)), "l"),
            item(L("Search"), #selector(ExplorerController.focusSearch(_:)), "f"),
            .separator(),
            item(L("Home"), #selector(ExplorerController.goHome(_:)), "h", [.command, .shift]),
            item(L("Desktop"), #selector(ExplorerController.goDesktop(_:)), "d", [.command, .shift]),
            item(L("Downloads"), #selector(ExplorerController.goDownloads(_:)), "l", [.command, .option]),
            item(L("Applications"), #selector(ExplorerController.goApplications(_:)), "a", [.command, .shift]),
        ])
        let win = submenu(L("Window"), [
            item(L("Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"),
            item(L("Zoom"), #selector(NSWindow.performZoom(_:)), ""),
            .separator(),
            item(L("Previous Tab"), #selector(NSWindow.selectPreviousTab(_:)), "{", [.command, .shift]),
            item(L("Next Tab"), #selector(NSWindow.selectNextTab(_:)), "}", [.command, .shift]),
        ])
        NSApp.mainMenu = main
        NSApp.windowsMenu = win
    }
}

// MARK: - Start

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
