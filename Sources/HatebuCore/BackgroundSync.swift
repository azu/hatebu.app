import Foundation
import CBackground

public enum BackgroundSync {
    @discardableResult public static func start(paths: DataPaths, executable: String, full: Bool = false, force: Bool = false) -> Bool {
        let command = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
        guard FileManager.default.isExecutableFile(atPath: command) else { return false }
        let args = [command, "sync"] + (full ? ["--full"] : (force ? [] : ["--if-stale"])) + ["--data-dir", paths.root.path]
        var pointers = args.map { strdup($0) } + [nil]
        defer { pointers.forEach { free($0) } }
        return pointers.withUnsafeMutableBufferPointer { hatebu_spawn_detached(command, $0.baseAddress!) == 0 }
    }
}
