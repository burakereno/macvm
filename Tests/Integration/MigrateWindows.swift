import Foundation
import WindowsPrototypeCore

@main struct MigrateWindows {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { fatalError("Usage: MigrateWindows source destination-folder") }
        let entry = try WindowsMigration.migrate(from: URL(fileURLWithPath: CommandLine.arguments[1]), to: URL(fileURLWithPath: CommandLine.arguments[2]))
        print(entry.url.path)
    }
}
