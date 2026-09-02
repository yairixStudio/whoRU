import Foundation

/// The kinds of permission a system dialog can ask for.
///
/// Raw values are the macOS TCC service names so that they round-trip through
/// `tccutil` and `TCC.db`. Other platforms map their own consent categories onto
/// the closest case and use `.other` for the rest.
public enum PermissionService: String, Codable, Sendable, CaseIterable, Hashable {
    case networkVolumes = "SystemPolicyNetworkVolumes"
    case removableVolumes = "SystemPolicyRemovableVolumes"
    case desktopFolder = "SystemPolicyDesktopFolder"
    case documentsFolder = "SystemPolicyDocumentsFolder"
    case downloadsFolder = "SystemPolicyDownloadsFolder"
    case fullDiskAccess = "SystemPolicyAllFiles"
    case camera = "Camera"
    case microphone = "Microphone"
    case screenCapture = "ScreenCapture"
    case contacts = "AddressBook"
    case calendar = "Calendar"
    case reminders = "Reminders"
    case photos = "Photos"
    case appleEvents = "AppleEvents"
    case inputMonitoring = "ListenEvent"
    case accessibility = "Accessibility"
    case bluetooth = "BluetoothAlways"
    case speechRecognition = "SpeechRecognition"
    case location = "Location"
    /// Not TCC: the keychain's own dialog, "X wants to access key “Y” in your
    /// keychain". Who X is matters just as much.
    case keychain = "Keychain"
    /// Not TCC: the authorization dialog, "X wants to make changes".
    case adminRights = "AdminRights"
    case other = "Other"

    /// The name in the system's own log of the request, for services the
    /// system keeps in TCC; `nil` for the keychain and authorization dialogs.
    public var tccServiceName: String? {
        switch self {
        case .keychain, .adminRights, .other: nil
        default: "kTCCService" + rawValue
        }
    }

    /// Short identifier used on the command line and in settings, e.g. `downloadsFolder`.
    public var shortName: String {
        switch self {
        case .networkVolumes: "networkVolumes"
        case .removableVolumes: "removableVolumes"
        case .desktopFolder: "desktopFolder"
        case .documentsFolder: "documentsFolder"
        case .downloadsFolder: "downloadsFolder"
        case .fullDiskAccess: "fullDiskAccess"
        case .camera: "camera"
        case .microphone: "microphone"
        case .screenCapture: "screenCapture"
        case .contacts: "contacts"
        case .calendar: "calendar"
        case .reminders: "reminders"
        case .photos: "photos"
        case .appleEvents: "appleEvents"
        case .inputMonitoring: "inputMonitoring"
        case .accessibility: "accessibility"
        case .bluetooth: "bluetooth"
        case .speechRecognition: "speechRecognition"
        case .location: "location"
        case .keychain: "keychain"
        case .adminRights: "adminRights"
        case .other: "other"
        }
    }

    public init?(shortName: String) {
        guard let match = Self.allCases.first(where: { $0.shortName.caseInsensitiveCompare(shortName) == .orderedSame }) else {
            return nil
        }
        self = match
    }

    /// Whether this permission is broad enough that a request from a program
    /// without an obvious need should lower confidence.
    public var isSensitive: Bool {
        switch self {
        case .fullDiskAccess, .screenCapture, .inputMonitoring, .accessibility, .camera, .microphone, .keychain, .adminRights:
            true
        default:
            false
        }
    }
}

/// What the dialog said, as read from the screen.
///
/// `title` and `body` are hostile input: they were written by the requesting
/// program (the body is its own usage description) and must never be passed to
/// a shell or treated as instructions.
public struct PermissionPrompt: Codable, Sendable, Hashable {
    public var title: String
    public var body: String?
    public var requesterName: String
    public var service: PermissionService
    /// The free-text request phrase from the dialog, e.g. "access files on a network volume".
    public var requestPhrase: String
    /// For automation prompts, the app being controlled.
    public var target: String?
    /// BCP-47 language tag of the dialog text, when known.
    public var locale: String
    public var detectedAt: Date

    public init(
        title: String,
        body: String? = nil,
        requesterName: String,
        service: PermissionService,
        requestPhrase: String,
        target: String? = nil,
        locale: String = "en",
        detectedAt: Date = Date()
    ) {
        self.title = title
        self.body = body
        self.requesterName = requesterName
        self.service = service
        self.requestPhrase = requestPhrase
        self.target = target
        self.locale = locale
        self.detectedAt = detectedAt
    }
}
