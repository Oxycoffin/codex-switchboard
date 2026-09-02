import Foundation

enum BillingBrowser: String, CaseIterable, Codable, Identifiable {
    case webKit
    case chrome
    case edge
    case brave
    case vivaldi
    case opera

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .webKit: return "WebKit (Safari)"
        case .chrome: return "Google Chrome"
        case .edge: return "Microsoft Edge"
        case .brave: return "Brave"
        case .vivaldi: return "Vivaldi"
        case .opera: return "Opera"
        }
    }

    var executablePath: String? {
        switch self {
        case .webKit: return nil
        case .chrome: return "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        case .edge: return "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"
        case .brave: return "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"
        case .vivaldi: return "/Applications/Vivaldi.app/Contents/MacOS/Vivaldi"
        case .opera: return "/Applications/Opera.app/Contents/MacOS/Opera"
        }
    }

    var supportsIntegratedVPN: Bool { self == .opera }
    var isEmbedded: Bool { self == .webKit }
    var isInstalled: Bool {
        isEmbedded || executablePath.map(FileManager.default.isExecutableFile(atPath:)) == true
    }

    static var recommended: BillingBrowser {
        .webKit
    }
}

enum BrowserProfileLocator {
    static func root(profileRoot: URL, browser: BillingBrowser, legacyOperaPath: String?) -> URL {
        if browser == .opera,
           let legacyOperaPath,
           URL(fileURLWithPath: legacyOperaPath, isDirectory: true).lastPathComponent == "Opera" {
            return URL(fileURLWithPath: legacyOperaPath, isDirectory: true).standardizedFileURL
        }
        return profileRoot
            .appendingPathComponent("Browsers", isDirectory: true)
            .appendingPathComponent(browser.rawValue, isDirectory: true)
    }
}
