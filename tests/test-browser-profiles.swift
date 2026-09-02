import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("failed: \(message)\n".utf8))
        exit(1)
    }
}

@main
struct BrowserProfileTests {
    static func main() {
        let account = URL(fileURLWithPath: "/tmp/profiles/account-id", isDirectory: true)
        let legacyOpera = account.appendingPathComponent("Opera", isDirectory: true).path
        let opera = BrowserProfileLocator.root(profileRoot: account, browser: .opera, legacyOperaPath: legacyOpera)
        let chrome = BrowserProfileLocator.root(profileRoot: account, browser: .chrome, legacyOperaPath: legacyOpera)
        let edge = BrowserProfileLocator.root(profileRoot: account, browser: .edge, legacyOperaPath: legacyOpera)

        expect(opera.path == legacyOpera, "Opera keeps its existing isolated profile")
        expect(chrome.path.hasSuffix("/Browsers/chrome"), "Chrome gets its own isolated profile")
        expect(edge.path.hasSuffix("/Browsers/edge"), "Edge gets its own isolated profile")
        expect(chrome != edge && chrome != opera, "browser profiles never share storage")
        expect(BillingBrowser.recommended == .webKit, "embedded WebKit is the dependency-free default")
        expect(BillingBrowser.allCases.allSatisfy { !$0.displayName.isEmpty }, "every browser has a name")
        expect(BillingBrowser.allCases.filter { !$0.isEmbedded }.allSatisfy { $0.executablePath?.isEmpty == false },
               "every external browser has an executable")

        print("browser profile isolation tests passed")
    }
}
