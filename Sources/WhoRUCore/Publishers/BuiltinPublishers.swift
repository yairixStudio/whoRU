import Foundation

/// Publishers whose Team IDs were verified from a real code signature
/// (`codesign -dv --verbose=2 /Applications/<App>.app`). To add one, open a
/// pull request with the command output in the description.
///
/// `knownNames` are product names a legitimate build from this publisher
/// shows in a permission dialog. A requester using one of these names without
/// this publisher's signature is flagged as impersonation.
public enum BuiltinPublishers {
    public static let all: [Publisher] = [
        Publisher(
            teamID: Publisher.appleTeamID, name: "Apple",
            knownNames: [
                "Finder", "Safari", "Mail", "Messages", "FaceTime", "Photos", "Music", "TV", "Podcasts", "News",
                "Notes", "Reminders", "Calendar", "Contacts", "Maps", "Terminal", "Xcode", "System Settings",
                "System Preferences", "App Store", "Preview", "TextEdit", "Screen Sharing", "Spotlight", "Siri",
                "Shortcuts", "Automator", "Script Editor", "Console", "Activity Monitor", "Disk Utility", "Keychain Access",
                "Keynote", "Numbers", "Pages", "iMovie", "GarageBand", "Final Cut Pro", "Logic Pro",
            ]
        ),
        Publisher(
            teamID: "Q6L2SF6YDW", name: "Anthropic PBC",
            knownNames: ["Claude", "Claude Code", "claude"],
            manifest: ManifestSource(
                urlTemplate: "https://downloads.claude.ai/claude-code-releases/{version}/manifest.json",
                identifiers: ["com.anthropic.claude-code", "claude"],
                format: "claudeCode",
                platformKey: "darwin-arm64"
            )
        ),
        Publisher(teamID: "EQHXZ8M8AV", name: "Google LLC", knownNames: ["Google Chrome", "Google Chrome Helper", "Google Drive", "Antigravity"]),
        Publisher(teamID: "UBF8T346G9", name: "Microsoft Corporation", knownNames: ["Microsoft Outlook", "Microsoft Word", "Microsoft Excel", "Microsoft PowerPoint", "Microsoft Teams", "Microsoft Edge", "Visual Studio Code", "OneDrive"]),
        Publisher(teamID: "2DC432GLL2", name: "OpenAI", knownNames: ["ChatGPT", "ChatGPT Atlas", "Codex"]),
        Publisher(teamID: "T8RA8NE3B7", name: "Figma, Inc.", knownNames: ["Figma"]),
        Publisher(teamID: "BJ4HAAB9B3", name: "Zoom Video Communications, Inc.", knownNames: ["zoom.us", "Zoom"]),
        Publisher(teamID: "57T9237FN3", name: "WhatsApp Inc.", knownNames: ["WhatsApp"]),
        Publisher(teamID: "6N38VWS5BX", name: "Telegram FZ-LLC", knownNames: ["Telegram"]),
        Publisher(teamID: "75GAHG3SZQ", name: "VideoLAN", knownNames: ["VLC"]),
        Publisher(teamID: "VDXQ22DGB9", name: "Cursor (Anysphere Inc.)", knownNames: ["Cursor"]),
        Publisher(teamID: "KHRWM533LU", name: "AnyDesk Software GmbH", knownNames: ["AnyDesk"]),
        Publisher(teamID: "W5W395V82Y", name: "Nord Security", knownNames: ["NordVPN"]),
        Publisher(teamID: "WDNLXAD4W8", name: "UTM (Turing Software)", knownNames: ["UTM"]),
        Publisher(teamID: "X93LWC49WV", name: "SwiftBar", knownNames: ["SwiftBar"]),
        Publisher(teamID: "7S8W4W365S", name: "Perplexity AI", knownNames: ["Comet"]),
        Publisher(teamID: "43AQ936H96", name: "Mozilla Corporation", knownNames: ["Firefox", "Thunderbird"]),
        Publisher(teamID: "2ZEFAR8TH3", name: "JetBrains s.r.o.", knownNames: ["IntelliJ IDEA", "PyCharm", "WebStorm", "GoLand", "CLion", "RubyMine", "Rider", "DataGrip", "JetBrains Toolbox"]),
        Publisher(teamID: "JQ525L2MZD", name: "Adobe Inc.", knownNames: ["Adobe Photoshop", "Adobe Illustrator", "Adobe Acrobat", "Adobe Creative Cloud", "Adobe Premiere Pro", "Adobe Lightroom"]),
        Publisher(teamID: "BQR82RBBHL", name: "Slack Technologies, Inc.", knownNames: ["Slack"]),
        Publisher(teamID: "G7HH3F8CAK", name: "Dropbox, Inc.", knownNames: ["Dropbox"]),
        Publisher(teamID: "2FNC3A47ZF", name: "Spotify", knownNames: ["Spotify"]),
        Publisher(teamID: "53Q6R32WPB", name: "Discord, Inc.", knownNames: ["Discord"]),
        Publisher(teamID: "2BUA8C4S2C", name: "AgileBits Inc. (1Password)", knownNames: ["1Password"]),
        Publisher(teamID: "9BNSXJN65R", name: "Docker Inc", knownNames: ["Docker", "Docker Desktop"]),
        Publisher(teamID: "LBQJ96FQ8D", name: "Notion Labs, Inc.", knownNames: ["Notion"]),
        Publisher(teamID: "SY64MV22J9", name: "Raycast Technologies Ltd", knownNames: ["Raycast"]),
        Publisher(teamID: "XZZXE9SED4", name: "Running with Crayons Ltd (Alfred)", knownNames: ["Alfred"]),
    ]
}
