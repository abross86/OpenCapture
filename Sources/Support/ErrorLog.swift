import Foundation
import Combine

/// App-wide error/event log shown in the Errors window. Thread-safe: entries are appended on the main queue.
final class ErrorLog: ObservableObject {
    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let category: String
        let message: String
        let code: Int
    }
    static let shared = ErrorLog()
    @Published private(set) var entries: [Entry] = []

    /// Also mirrored to ~/Library/Logs/OpenCapture.log for troubleshooting.
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/OpenCapture.log")
    private static let fileQueue = DispatchQueue(label: "org.opencapture.log")
    private static let stamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f }()

    func log(_ category: String, _ message: String, code: Int = 0) {
        NSLog("[%@] %@ (code %d)", category, message, code)
        let line = "\(Self.stamp.string(from: Date())) [\(category)] \(message)\(code != 0 ? " (code \(code))" : "")\n"
        Self.fileQueue.async {
            let url = Self.fileURL
            if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
            else { try? line.data(using: .utf8)!.write(to: url) }
        }
        let entry = Entry(date: Date(), category: category, message: message, code: code)
        if Thread.isMainThread { append(entry) } else { DispatchQueue.main.async { self.append(entry) } }
    }
    func clear() { entries.removeAll() }
    private func append(_ e: Entry) {
        entries.append(e)
        if entries.count > 500 { entries.removeFirst(entries.count - 500) }
    }
}
