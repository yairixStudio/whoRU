import Foundation
import Testing
import WhoRUCore
@testable import WhoRUMac

@Suite struct OpenFilesToolTests {
    @Test func reportsFoldersAndCountsButNeverFileNames() {
        let home = "/Users/me"
        let paths = [
            "/Users/me/Documents/taxes-2025.pdf",
            "/Users/me/Documents/diary.txt",
            "/Users/me/Documents/diary.txt",
            "/Users/me/Desktop/notes.md",
            "/Volumes/Backup/photo.jpg",
            "/Users/me/Library/Caches/thing/blob",
            "/Users/me/lib/x.dylib",
            "/private/tmp/socket",
            "/System/Library/Frameworks/AppKit.framework/AppKit",
        ]
        let result = MacTools.openFileFolders(paths, home: home)
        #expect(result.folders == ["/Volumes/Backup", "~/Desktop", "~/Documents"])
        #expect(result.fileCount == 4)
        let joined = result.folders.joined(separator: "\n")
        for name in ["taxes-2025.pdf", "diary.txt", "notes.md", "photo.jpg", "/Users/me"] {
            #expect(!joined.contains(name), Comment(rawValue: name))
        }
    }

    @Test func foldersAreCapped() {
        let paths = (0..<40).map { "/Users/me/Documents/project-\(String(format: "%02d", $0))/file.txt" }
        let result = MacTools.openFileFolders(paths, home: "/Users/me")
        #expect(result.folders.count == 25)
        #expect(result.fileCount == 40)
        #expect(result.folders.first == "~/Documents/project-00")
    }
}
