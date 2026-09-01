import AppKit
import Darwin
import Foundation
import SwiftUI

@MainActor
final class LifecycleCoordinator {
    static let shared = LifecycleCoordinator()
    var managedCodexRestart = false
}

struct UsageWindow: Codable, Hashable {
    var usedPercent: Int
    var resetsAt: Date?
    var durationMinutes: Int?

    func current(at date: Date) -> UsageWindow {
        guard let resetsAt, resetsAt <= date else { return self }
        return UsageWindow(usedPercent: 0, resetsAt: nil, durationMinutes: durationMinutes)
    }

    var currentValue: UsageWindow { current(at: Date()) }
}

enum PreciseTime {
    static func remaining(until date: Date, now: Date = Date()) -> String {
        let total = max(0, Int(ceil(date.timeIntervalSince(now))))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 { return String(format: "%d h %02d min %02d s", hours, minutes, seconds) }
        if minutes > 0 { return String(format: "%d min %02d s", minutes, seconds) }
        return "\(seconds) s"
    }
}

enum L10n {
    static var isEnglish: Bool { Bundle.main.preferredLocalizations.first == "en" }
    static func text(_ spanish: String, _ english: String) -> String { isEnglish ? english : spanish }
}

struct AccountProfile: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var codexHome: String
    var browserData: String
    var email: String?
    var plan: String?
    var primary: UsageWindow?
    var secondary: UsageWindow?
    var limitReason: String?
    var activatedAt: Date? = nil
    var lastChecked: Date?
    var lastAttempted: Date? = nil
    var lastError: String?
    var resetCreditsAvailable: Int? = nil
    var spendControlReached: Bool? = nil
    var rateLimitID: String? = nil
    var isEnabled: Bool
    var isCurrentInstallation: Bool

    var isSignedIn: Bool { email != nil || plan != nil }
    var planDisplayName: String {
        guard let rawPlan = plan?.trimmingCharacters(in: .whitespacesAndNewlines), !rawPlan.isEmpty else {
            return isSignedIn ? L10n.text("Plan no disponible", "Plan unavailable") : L10n.text("Sin conectar", "Not connected")
        }
        switch rawPlan.lowercased().replacingOccurrences(of: "_", with: "") {
        case "free": return "Free"
        case "go": return "Go"
        case "plus": return "Plus"
        case "prolite": return "Pro Lite"
        case "pro": return "Pro"
        case "team": return "Team"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        case "edu", "education": return "Edu"
        default:
            return rawPlan.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
    var currentPrimary: UsageWindow? { primary?.currentValue }
    var currentSecondary: UsageWindow? { secondary?.currentValue }
    private var hasCurrentBackendBlock: Bool {
        guard limitReason != nil else { return false }
        let windows = [primary, secondary].compactMap { $0 }
        guard let likelyBlocking = windows.max(by: { $0.usedPercent < $1.usedPercent }) else {
            return lastChecked.map { Date().timeIntervalSince($0) < 30 * 60 } ?? false
        }
        return likelyBlocking.resetsAt.map { $0 > Date() } ?? true
    }
    var isExhausted: Bool {
        hasCurrentBackendBlock
            || (currentPrimary?.usedPercent ?? 0) >= 100
            || (currentSecondary?.usedPercent ?? 0) >= 100
    }
    var isBackendBlocked: Bool { hasCurrentBackendBlock }
    var hasReliableQuota: Bool { lastChecked != nil && lastError == nil }
    var shortRemaining: Int? { currentPrimary.map { max(0, 100 - $0.usedPercent) } }
    var weeklyRemaining: Int? { currentSecondary.map { max(0, 100 - $0.usedPercent) } }
    var availableScore: Int {
        guard isSignedIn, isEnabled, hasReliableQuota, !isExhausted else { return -1 }
        let known = [shortRemaining, weeklyRemaining].compactMap { $0 }
        guard let bottleneck = known.min() else { return -1 }
        // Protect the scarcer window first. Weekly availability breaks ties,
        // then the short window; this avoids burning a nearly depleted week.
        return bottleneck * 10_000 + (weeklyRemaining ?? bottleneck) * 100 + (shortRemaining ?? bottleneck)
    }
}

struct SwitchEvent: Codable, Identifiable, Hashable {
    let id: UUID
    let date: Date
    let kind: String
    let message: String
}

struct PersistedState: Codable {
    var profiles: [AccountProfile]
    var selectedID: UUID?
    var activeID: UUID?
    var automaticRotation: Bool
    var refreshMinutes: Int
    var pendingLimitAccountID: UUID?
    var pendingLimitDetectedAt: Date?
    var pendingLimitExpiresAt: Date?
    var events: [SwitchEvent]?
    var seamlessSwitching: Bool?
    var windowPrimingEnabled: Bool?
    var windowPrimingModel: String?
    var windowPrimingEffort: String?
}

struct ProbeResult {
    var email: String?
    var plan: String?
    var primary: UsageWindow?
    var secondary: UsageWindow?
    var limitReason: String?
    var resetCreditsAvailable: Int?
    var spendControlReached: Bool?
    var rateLimitID: String?
    var integrationVersion: String?
}

struct PrimingModelOption: Identifiable, Hashable {
    let id: String
    let displayName: String
    let efforts: [String]
}

struct WindowPrimingRecord: Codable, Hashable {
    var email: String
    var checkedAt: Date
    var anchoredAt: Date?
    var resetAt: Date?
    var model: String
    var effort: String
    var status: String
    var error: String?
}

private struct WindowPrimingLedger: Codable {
    var updatedAt: Date
    var accounts: [String: WindowPrimingRecord]
}

struct CredentialSwitchJournal: Codable {
    var fromID: UUID?
    var toID: UUID
    var phase: String
}

enum SwitchboardError: LocalizedError {
    case codexMissing
    case serverEnded
    case invalidResponse(String)
    case loginFailed(String)

    var errorDescription: String? {
        switch self {
        case .codexMissing: return L10n.text("No encuentro Codex en /Applications/ChatGPT.app.", "Codex was not found at /Applications/ChatGPT.app.")
        case .serverEnded: return L10n.text("El servidor local de Codex terminó antes de responder.", "The local Codex server exited before responding.")
        case .invalidResponse(let message): return L10n.text("Respuesta no válida de Codex: \(message)", "Invalid response from Codex: \(message)")
        case .loginFailed(let message): return L10n.text("No se pudo iniciar sesión: \(message)", "Sign-in failed: \(message)")
        }
    }
}

final class AppServerSession {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let error = Pipe()
    private var buffer = Data()
    private var nextID = 1
    private let timeoutLock = NSLock()
    private var timeoutTriggered = false

    init(codexHome: String) throws {
        let binary = "/Applications/ChatGPT.app/Contents/Resources/codex"
        guard FileManager.default.isExecutableFile(atPath: binary) else { throw SwitchboardError.codexMissing }
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["app-server", "--stdio"]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = codexHome
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        try process.run()
    }

    deinit { stop() }

    func stop() {
        if process.isRunning { process.terminate() }
    }

    func initialize() throws -> String? {
        let id = try send(method: "initialize", params: [
            "clientInfo": ["name": "codex-switchboard", "title": "Codex Switchboard", "version": "0.3.6"],
            "capabilities": ["experimentalApi": true]
        ])
        let result = try waitForResponse(id: id, timeout: 12)
        try sendNotification(method: "initialized")
        return result["userAgent"] as? String
    }

    func request(method: String, params: Any? = nil, timeout: TimeInterval = 20) throws -> [String: Any] {
        let id = try send(method: method, params: params)
        return try waitForResponse(id: id, timeout: timeout)
    }

    func waitForNotification(method: String, timeout: TimeInterval) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        return try withWatchdog(timeout: timeout) {
            while Date() < deadline {
                let message = try readMessage(deadline: deadline)
                if message["method"] as? String == method {
                    return message["params"] as? [String: Any] ?? [:]
                }
            }
            throw SwitchboardError.invalidResponse("tiempo de espera agotado")
        }
    }

    private func send(method: String, params: Any?) throws -> Int {
        let id = nextID
        nextID += 1
        var object: [String: Any] = ["id": id, "method": method]
        if let params { object["params"] = params }
        try write(object)
        return id
    }

    private func sendNotification(method: String) throws {
        try write(["method": method])
    }

    private func write(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    private func waitForResponse(id: Int, timeout: TimeInterval) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        return try withWatchdog(timeout: timeout) {
            while Date() < deadline {
                let message = try readMessage(deadline: deadline)
                if let responseID = message["id"] as? Int, responseID == id {
                    if let rpcError = message["error"] as? [String: Any] {
                        throw SwitchboardError.invalidResponse(rpcError["message"] as? String ?? "error desconocido")
                    }
                    return message["result"] as? [String: Any] ?? [:]
                }
            }
            throw SwitchboardError.invalidResponse("tiempo de espera agotado")
        }
    }

    private func withWatchdog<T>(timeout: TimeInterval, operation: () throws -> T) throws -> T {
        timeoutLock.lock()
        timeoutTriggered = false
        timeoutLock.unlock()
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.timeoutLock.lock()
            self.timeoutTriggered = true
            self.timeoutLock.unlock()
            if self.process.isRunning { self.process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer { watchdog.cancel() }
        do {
            return try operation()
        } catch {
            timeoutLock.lock()
            let timedOut = timeoutTriggered
            timeoutLock.unlock()
            if timedOut { throw SwitchboardError.invalidResponse("tiempo de espera agotado") }
            throw error
        }
    }

    private func readMessage(deadline: Date) throws -> [String: Any] {
        while Date() < deadline {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                guard !line.isEmpty,
                      let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                return object
            }
            let data = output.fileHandleForReading.availableData
            if data.isEmpty { throw SwitchboardError.serverEnded }
            buffer.append(data)
        }
        throw SwitchboardError.invalidResponse("tiempo de espera agotado")
    }
}

enum CodexBridge {
    static func probe(home: String, includeRateLimits: Bool = true, refreshToken: Bool = false) throws -> ProbeResult {
        let session = try AppServerSession(codexHome: home)
        defer { session.stop() }
        let integrationVersion = try session.initialize()
        let account = try session.request(method: "account/read", params: ["refreshToken": refreshToken])
        let limits = includeRateLimits ? try session.request(method: "account/rateLimits/read") : [:]

        let accountObject = account["account"] as? [String: Any]
        let legacySnapshot = limits["rateLimits"] as? [String: Any]
        let snapshots = limits["rateLimitsByLimitId"] as? [String: Any]
        let codexSnapshot = snapshots?["codex"] as? [String: Any]
        let snapshot = codexSnapshot ?? legacySnapshot
        let resetCredits = limits["rateLimitResetCredits"] as? [String: Any]
        return ProbeResult(
            email: accountObject?["email"] as? String,
            plan: (accountObject?["planType"] as? String) ?? (snapshot?["planType"] as? String),
            primary: usageWindow(snapshot?["primary"]),
            secondary: usageWindow(snapshot?["secondary"]),
            limitReason: (snapshot?["rateLimitReachedType"] as? String)
                ?? ((snapshot?["spendControlReached"] as? Bool) == true ? "spend_control_reached" : nil),
            resetCreditsAvailable: resetCredits?["availableCount"] as? Int,
            spendControlReached: snapshot?["spendControlReached"] as? Bool,
            rateLimitID: snapshot?["limitId"] as? String,
            integrationVersion: integrationVersion
        )
    }

    static func login(home: String, openURL: @escaping (URL) -> Void) throws {
        let session = try AppServerSession(codexHome: home)
        defer { session.stop() }
        _ = try session.initialize()
        let result = try session.request(method: "account/login/start", params: [
            "type": "chatgpt",
            "codexStreamlinedLogin": true,
            "useHostedLoginSuccessPage": true,
            "appBrand": "codex"
        ])
        guard let urlText = result["authUrl"] as? String, let url = URL(string: urlText) else {
            throw SwitchboardError.invalidResponse("Codex no devolvió una URL de acceso")
        }
        openURL(url)
        let completed = try session.waitForNotification(method: "account/login/completed", timeout: 300)
        guard completed["success"] as? Bool == true else {
            throw SwitchboardError.loginFailed(completed["error"] as? String ?? "acceso cancelado")
        }
    }

    static func logout(home: String) throws {
        let session = try AppServerSession(codexHome: home)
        defer { session.stop() }
        _ = try session.initialize()
        _ = try session.request(method: "account/logout")
    }

    static func prepareHotSwitch(home: String) throws {
        _ = try probe(home: home, includeRateLimits: false, refreshToken: true)
        let auth = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("auth.json")
        guard FileManager.default.fileExists(atPath: auth.path) else {
            throw SwitchboardError.loginFailed("el perfil de destino no contiene una sesión activa")
        }
    }

    static func primingModels(home: String) throws -> [PrimingModelOption] {
        let session = try AppServerSession(codexHome: home)
        defer { session.stop() }
        _ = try session.initialize()
        let result = try session.request(method: "model/list", params: ["limit": 100])
        let models = result["data"] as? [[String: Any]] ?? []
        return models.compactMap { model in
            guard model["hidden"] as? Bool != true,
                  let id = (model["model"] as? String) ?? (model["id"] as? String) else { return nil }
            let efforts = (model["supportedReasoningEfforts"] as? [[String: Any]] ?? [])
                .compactMap { $0["reasoningEffort"] as? String }
            return PrimingModelOption(
                id: id,
                displayName: model["displayName"] as? String ?? id,
                efforts: efforts
            )
        }
    }

    private static func usageWindow(_ value: Any?) -> UsageWindow? {
        guard let object = value as? [String: Any], let used = object["usedPercent"] as? Int else { return nil }
        let reset = (object["resetsAt"] as? TimeInterval).map(Date.init(timeIntervalSince1970:))
            ?? (object["resetsAt"] as? Int).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        return UsageWindow(usedPercent: used, resetsAt: reset, durationMinutes: object["windowDurationMins"] as? Int)
    }
}

struct HotBridgeStatus: Codable {
    var pid: Int32
    var ready: Bool
    var version: String
    var startedAt: Date
    var updatedAt: Date
    var activeThreadID: String?
    var activeTurnID: String?
    var activeItems: Int
    var pendingLimitThreadID: String?
    var pendingLimitTurnID: String?
    var pendingLimitAt: Date?
    var pendingLimitProfileID: String?
    var activeProfileID: String?
    var lastSwitchAt: Date?
    var lastError: String?
    var rateLimits: HotBridgeRateLimits?
    var rateLimitsUpdatedAt: Date?
}

struct HotBridgeUsageWindow: Codable {
    var usedPercent: Int
    var resetsAt: Date?
    var windowDurationMins: Int?

    var usageWindow: UsageWindow {
        UsageWindow(usedPercent: usedPercent, resetsAt: resetsAt, durationMinutes: windowDurationMins)
    }
}

struct HotBridgeRateLimits: Codable {
    var primary: HotBridgeUsageWindow?
    var secondary: HotBridgeUsageWindow?
    var rateLimitReachedType: String?
    var spendControlReached: Bool?
}

enum HotBridgeClient {
    static let expectedVersion = "0.3.6"
    private static var runtimeDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Codex Switchboard/Bridge", isDirectory: true)
    }
    private static var commandsDirectory: URL { runtimeDirectory.appendingPathComponent("Commands", isDirectory: true) }
    private static var statusFile: URL { runtimeDirectory.appendingPathComponent("status.json") }

    static func rawStatus() -> HotBridgeStatus? {
        guard let data = try? Data(contentsOf: statusFile) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let value = try? decoder.decode(HotBridgeStatus.self, from: data),
              kill(value.pid, 0) == 0 else { return nil }
        return value
    }

    static func status() -> HotBridgeStatus? {
        guard let value = rawStatus(), value.ready, value.version == expectedVersion else { return nil }
        return value
    }

    static func command(_ values: [String: Any], timeout: TimeInterval = 12) throws -> [String: Any] {
        let manager = FileManager.default
        try manager.createDirectory(at: commandsDirectory, withIntermediateDirectories: true)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runtimeDirectory.path)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: commandsDirectory.path)
        let id = UUID().uuidString
        let request = commandsDirectory.appendingPathComponent("request-\(id).json")
        let response = commandsDirectory.appendingPathComponent("response-\(id).json")
        let temporary = commandsDirectory.appendingPathComponent(".request-\(id).tmp")
        let data = try JSONSerialization.data(withJSONObject: values)
        try data.write(to: temporary, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        try manager.moveItem(at: temporary, to: request)
        defer {
            try? manager.removeItem(at: request)
            try? manager.removeItem(at: response)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if manager.fileExists(atPath: response.path) {
                let object = try JSONSerialization.jsonObject(with: Data(contentsOf: response)) as? [String: Any] ?? [:]
                if object["ok"] as? Bool == true { return object }
                throw SwitchboardError.invalidResponse(object["error"] as? String ?? "el bridge rechazó el cambio")
            }
            Thread.sleep(forTimeInterval: 0.03)
        }
        throw SwitchboardError.invalidResponse("el bridge no respondió; se conserva el modo seguro")
    }
}

@MainActor
final class SwitchboardStore: ObservableObject {
    @Published var profiles: [AccountProfile] = []
    @Published var selectedID: UUID?
    @Published var activeID: UUID?
    @Published var automaticRotation = false
    @Published var seamlessSwitching = true
    @Published var bridgeConnected = false
    @Published var bridgeVersion: String?
    @Published var refreshMinutes = 1
    @Published var isRefreshing = false
    @Published var statusMessage: String?
    @Published var showingAutoRotationWarning = false
    @Published var showingForceSwitchWarning = false
    @Published var blockingTaskNames: [String] = []
    @Published var events: [SwitchEvent] = []
    @Published var integrationVersion: String?
    @Published var windowPrimingEnabled = true
    @Published var windowPrimingModel = "gpt-5.6-luna"
    @Published var windowPrimingEffort = "low"
    @Published var primingModels: [PrimingModelOption] = []
    @Published var windowPrimingRecords: [String: WindowPrimingRecord] = [:]

    private let manager = FileManager.default
    private var timer: Timer?
    private var rotationRetryTask: Task<Void, Never>?
    private var limitMonitorTask: Task<Void, Never>?
    private var isRotationInFlight = false
    private var isReactiveRefreshInFlight = false
    private var lastObservedTerminalTurnAt: Int64?
    private var lastCandidateRefreshAt: Date?
    private var pendingManualSwitchID: UUID?
    private var waitingForCapacityAccountID: UUID?
    private var pendingLimitAccountID: UUID?
    private var pendingLimitDetectedAt: Date?
    private var pendingLimitExpiresAt: Date?
    private var lastBridgeLimitAt: Date?
    private var bridgeCommitProfileID: UUID?
    private var lastAppliedBridgeRateLimitsAt: Date?

    private var support: URL {
        manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Codex Switchboard", isDirectory: true)
    }
    private var stateFile: URL { support.appendingPathComponent("state.json") }
    private var windowPrimingFile: URL { support.appendingPathComponent("window-priming-state.json") }
    private var switchJournalFile: URL { support.appendingPathComponent("credential-switch.json") }
    private var profilesRoot: URL { support.appendingPathComponent("Profiles", isDirectory: true) }
    private var sharedCodexHome: URL { manager.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true) }

    init() {
        load()
        refreshWindowPrimingStatus()
        scheduleTimer()
        scheduleLimitMonitor()
        Task {
            await refreshPrimingModels()
            await refreshAll()
        }
    }

    var selected: AccountProfile? { profiles.first { $0.id == selectedID } }
    var active: AccountProfile? { profiles.first { $0.id == activeID } }
    var recommendedNext: AccountProfile? {
        guard let active else { return nil }
        return bestAvailable(excluding: active.id)
    }
    var forceSwitchMessage: String {
        let names = blockingTaskNames.prefix(3).joined(separator: "\n• ")
        let list = names.isEmpty ? "" : "\n\n• \(names)"
        return "Codex registra actividad en estas tareas:\(list)\n\nForzar cerrará Codex y puede interrumpir trabajo que aún no se haya guardado."
    }

    func addProfile(name rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let id = UUID()
        let root = profilesRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        let home = root.appendingPathComponent("Account", isDirectory: true)
        let browser = root.appendingPathComponent("Opera", isDirectory: true)
        do {
            try secureDirectory(root)
            try secureDirectory(home)
            try secureDirectory(browser)
            let config = home.appendingPathComponent("config.toml")
            if !manager.fileExists(atPath: config.path) {
                let note = "# Almacén de autenticación aislado. El historial permanece en ~/.codex.\ncli_auth_credentials_store = \"file\"\n"
                try note.write(to: config, atomically: true, encoding: .utf8)
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
            }
            profiles.append(AccountProfile(id: id, name: name, codexHome: home.path, browserData: browser.path,
                                           email: nil, plan: nil, primary: nil, secondary: nil, limitReason: nil,
                                           lastChecked: nil, lastError: nil, isEnabled: true, isCurrentInstallation: false))
            selectedID = id
            save()
        } catch { statusMessage = error.localizedDescription }
    }

    func delete(_ profile: AccountProfile) {
        guard profile.id != activeID else {
            statusMessage = L10n.text("Cambia primero a otra cuenta para poder eliminar esta.", "Switch to another account before deleting this one.")
            return
        }

        let profileRoot = URL(fileURLWithPath: profile.codexHome, isDirectory: true)
            .deletingLastPathComponent().standardizedFileURL
        let allowedRoot = profilesRoot.standardizedFileURL
        guard profileRoot.deletingLastPathComponent() == allowedRoot else {
            statusMessage = "No se eliminó la cuenta porque su carpeta local no es válida."
            return
        }

        do {
            var trashedURL: NSURL?
            if manager.fileExists(atPath: profileRoot.path) {
                try manager.trashItem(at: profileRoot, resultingItemURL: &trashedURL)
            }
            profiles.removeAll { $0.id == profile.id }
            if selectedID == profile.id { selectedID = profiles.first?.id }
            save()
            statusMessage = "Cuenta eliminada. Su sesión local está en la Papelera; las conversaciones de Codex se conservan."
        } catch {
            statusMessage = "No se pudo eliminar la cuenta: \(error.localizedDescription)"
        }
    }

    func rename(_ profile: AccountProfile, to rawName: String) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        profiles[index].name = name
        save()
    }

    func setRotationEnabled(_ enabled: Bool, for profile: AccountProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index].isEnabled = enabled
        recordEvent(kind: "policy", message: enabled
            ? "\(profile.name) participa en el cambio automático."
            : "\(profile.name) queda fuera del cambio automático.")
        save()
    }

    func setAutomaticRotation(_ enabled: Bool) {
        if enabled && !automaticRotation {
            showingAutoRotationWarning = true
        } else {
            automaticRotation = enabled
            if !enabled { waitingForCapacityAccountID = nil }
            save()
        }
    }

    func setSeamlessSwitching(_ enabled: Bool) {
        seamlessSwitching = enabled
        save()
        statusMessage = enabled
            ? "El cambio en vivo se usará cuando Codex esté conectado al bridge."
            : "El cambio en vivo está desactivado; Switchboard usará el cierre seguro."
    }

    func setWindowPrimingEnabled(_ enabled: Bool) {
        windowPrimingEnabled = enabled
        save()
        statusMessage = enabled
            ? "Preparación de ventanas activada. Funcionará en segundo plano mientras el Mac esté despierto."
            : "Preparación de ventanas desactivada."
    }

    func setWindowPrimingModel(_ model: String) {
        windowPrimingModel = model
        let supported = primingModels.first { $0.id == model }?.efforts ?? []
        if !supported.contains(windowPrimingEffort) {
            windowPrimingEffort = supported.contains("low") ? "low" : (supported.first ?? "low")
        }
        save()
    }

    func setWindowPrimingEffort(_ effort: String) {
        windowPrimingEffort = effort
        save()
    }

    func refreshPrimingModels() async {
        do {
            let models = try await Task.detached(priority: .utility) {
                try CodexBridge.primingModels(home: FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".codex", isDirectory: true).path)
            }.value
            primingModels = models
            let supported = models.first { $0.id == windowPrimingModel }?.efforts ?? []
            if !supported.isEmpty, !supported.contains(windowPrimingEffort) {
                windowPrimingEffort = supported.contains("low") ? "low" : supported[0]
                save()
            }
        } catch {
            if primingModels.isEmpty {
                primingModels = [PrimingModelOption(id: windowPrimingModel,
                                                    displayName: windowPrimingModel,
                                                    efforts: [windowPrimingEffort])]
            }
        }
    }

    var primingEfforts: [String] {
        let values = primingModels.first { $0.id == windowPrimingModel }?.efforts ?? []
        return values.isEmpty ? [windowPrimingEffort] : values
    }

    func windowPrimingRecord(for profile: AccountProfile) -> WindowPrimingRecord? {
        windowPrimingRecords[profile.id.uuidString]
    }

    private func refreshWindowPrimingStatus() {
        guard let data = try? Data(contentsOf: windowPrimingFile) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let ledger = try? decoder.decode(WindowPrimingLedger.self, from: data) {
            windowPrimingRecords = ledger.accounts
        }
    }

    func confirmAutomaticRotation() {
        automaticRotation = true
        showingAutoRotationWarning = false
        save()
    }

    func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        // The account visible in Codex is the latency-sensitive one. Refresh it
        // before walking the isolated inactive profiles.
        let snapshot = profiles.filter { $0.id == activeID }
            + profiles.filter { $0.id != activeID }
        let ids = snapshot.filter { $0.isEnabled || $0.id == activeID }.map(\.id)
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { await self.refresh(id) }
            }
        }
        isRefreshing = false
        refreshWindowPrimingStatus()
        if automaticRotation, let active {
            if waitingForCapacityAccountID == active.id {
                await handleConfirmedLimit(for: active)
                return
            }
            let confirmedLimit = active.isBackendBlocked
                || hasPendingOrRecentUsageLimit(for: active)
            if confirmedLimit {
                await handleConfirmedLimit(for: active)
            } else if active.isExhausted {
                if bestAvailable(excluding: active.id) == nil {
                    waitingForCapacityAccountID = active.id
                    statusMessage = "Todas las cuentas están agotadas. Switchboard cambiará automáticamente en cuanto alguna recupere uso."
                } else {
                    statusMessage = "La disponibilidad marca 0%, pero el backend aún permite uso. No se cambia durante la gracia."
                }
                scheduleRotationRetry()
            }
        }
    }

    func refresh(_ id: UUID) async {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        let isActiveProfile = activeID == profile.id
        let probeStartedAt = Date()
        do {
            let home = isActiveProfile ? sharedCodexHome.path : profile.codexHome
            let result = try await Task.detached(priority: .utility) {
                try CodexBridge.probe(home: home, includeRateLimits: true)
            }.value
            guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
            if let expected = profiles[index].email, let actual = result.email,
               expected.caseInsensitiveCompare(actual) != .orderedSame {
                throw SwitchboardError.invalidResponse("la sesión aislada pertenece a \(actual), no a \(expected)")
            }
            profiles[index].email = result.email
            if let email = result.email, isGenericName(profiles[index].name) {
                profiles[index].name = suggestedName(from: email)
            }
            profiles[index].plan = result.plan
            let livePushIsNewer = isActiveProfile
                && (lastAppliedBridgeRateLimitsAt.map { $0 > probeStartedAt } ?? false)
            if !livePushIsNewer {
                profiles[index].primary = result.primary
                profiles[index].secondary = result.secondary
                profiles[index].limitReason = result.limitReason
                profiles[index].resetCreditsAvailable = result.resetCreditsAvailable
                profiles[index].spendControlReached = result.spendControlReached
                profiles[index].rateLimitID = result.rateLimitID
                profiles[index].lastChecked = Date()
            }
            profiles[index].lastAttempted = Date()
            profiles[index].lastError = nil
            integrationVersion = result.integrationVersion
            save()
        } catch {
            guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
            profiles[index].lastAttempted = Date()
            let livePushIsNewer = isActiveProfile
                && (lastAppliedBridgeRateLimitsAt.map { $0 > probeStartedAt } ?? false)
            if !livePushIsNewer { profiles[index].lastError = error.localizedDescription }
            save()
        }
    }

    func signIn(_ profile: AccountProfile) {
        statusMessage = "Completa el acceso de \(profile.name) en el navegador."
        Task {
            do {
                let home = activeID == profile.id ? sharedCodexHome.path : profile.codexHome
                try await Task.detached {
                    try CodexBridge.login(home: home) { url in
                        DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                    }
                }.value
                statusMessage = "Sesión conectada."
                await refresh(profile.id)
            } catch { statusMessage = error.localizedDescription }
        }
    }

    func signOut(_ profile: AccountProfile) {
        if activeID == profile.id, hasInProgressTurn() {
            statusMessage = "Hay una tarea en curso. Espera a que termine antes de cerrar la sesión activa."
            return
        }
        Task {
            do {
                let home = activeID == profile.id ? sharedCodexHome.path : profile.codexHome
                try await Task.detached { try CodexBridge.logout(home: home) }.value
                if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
                    profiles[index].email = nil
                    profiles[index].plan = nil
                    profiles[index].primary = nil
                    profiles[index].secondary = nil
                    profiles[index].limitReason = nil
                    save()
                }
                statusMessage = "Sesión cerrada en \(profile.name). La cuenta sigue guardada en Switchboard."
            } catch { statusMessage = error.localizedDescription }
        }
    }

    func launch(_ profile: AccountProfile, automatic: Bool = false) {
        Task { await launchSingleInstance(profile, automatic: automatic, force: false) }
    }

    func confirmForcedSwitch() {
        guard let id = pendingManualSwitchID,
              let profile = profiles.first(where: { $0.id == id }) else {
            cancelForcedSwitch()
            return
        }
        pendingManualSwitchID = nil
        blockingTaskNames = []
        showingForceSwitchWarning = false
        Task { await launchSingleInstance(profile, automatic: false, force: true) }
    }

    func cancelForcedSwitch() {
        pendingManualSwitchID = nil
        blockingTaskNames = []
        showingForceSwitchWarning = false
        statusMessage = nil
    }

    func openProfileFolder(_ profile: AccountProfile) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: profile.codexHome)])
    }

    func requestPlanManagement(_ profile: AccountProfile) {
        selectedID = profile.id
        statusMessage = "Abriendo el perfil aislado de Opera para \(profile.email ?? profile.name)…"
        Task {
            do {
                let stage = try await Task.detached(priority: .userInitiated) {
                    try OperaPlanSession.open(profile: profile)
                }.value
                switch stage {
                case .vpnSetup:
                    statusMessage = "Activa la VPN en este perfil aislado de Opera y vuelve a pulsar Gestionar plan."
                case .billing:
                    statusMessage = "Perfil aislado abierto para \(profile.email ?? profile.name). Si ChatGPT pide acceso, inicia sesión y entra en Perfil → Ajustes → Billing."
                }
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    func updateRefreshMinutes(_ value: Int) {
        refreshMinutes = value
        scheduleTimer()
        save()
    }

    private func launchSingleInstance(_ profile: AccountProfile, automatic: Bool, force: Bool = false) async {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") else {
            statusMessage = SwitchboardError.codexMissing.localizedDescription
            return
        }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
        if activeID == profile.id, let app = running.first {
            app.activate(options: [.activateAllWindows])
            return
        }


        if !running.isEmpty, seamlessSwitching, HotBridgeClient.status() != nil {
            if await hotSwitch(profile, automatic: automatic) { return }
        }

        let runningTasks = activeTaskNames(usageLimitConfirmed: activeUsageLimitIsConfirmed)
        if !force, !runningTasks.isEmpty {
            if !automatic {
                pendingManualSwitchID = profile.id
                blockingTaskNames = runningTasks
                showingForceSwitchWarning = true
            }
            statusMessage = runningTasks.count == 1
                ? "Codex registra actividad en \(runningTasks[0]). Puedes esperar o forzar el cambio."
                : "Codex registra \(runningTasks.count) tareas activas. Puedes esperar o forzar el cambio."
            return
        }

        if !running.isEmpty {
            LifecycleCoordinator.shared.managedCodexRestart = true
            running.forEach { _ = $0.terminate() }
            let deadline = Date().addingTimeInterval(12)
            while Date() < deadline && !NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").isEmpty {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            if !NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").isEmpty {
                LifecycleCoordinator.shared.managedCodexRestart = false
                statusMessage = "Codex sigue ocupado. Cierra la tarea o la aplicación y vuelve a intentarlo."
                return
            }
        }

        do {
            try activateCredentials(for: profile)
        } catch {
            statusMessage = error.localizedDescription
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = sharedCodexHome.path
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/CodexHotBridge").path
        if seamlessSwitching, manager.isExecutableFile(atPath: helper) {
            environment["CODEX_CLI_PATH"] = helper
            environment["CODEX_SWITCHBOARD_ACTIVE_PROFILE_ID"] = profile.id.uuidString
        }
        configuration.environment = environment
        do {
            _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
            LifecycleCoordinator.shared.managedCodexRestart = false
            selectedID = profile.id
            save()
            await refresh(profile.id)
            statusMessage = automatic
                ? "Cambio automático a \(profile.name) completado."
                : "Codex abierto con \(profile.name)."
            recordEvent(kind: automatic ? "automatic" : "manual", message: statusMessage ?? "Cuenta cambiada.")
            save()
        } catch {
            LifecycleCoordinator.shared.managedCodexRestart = false
            statusMessage = error.localizedDescription
        }
    }

    private func hotSwitch(_ profile: AccountProfile, automatic: Bool) async -> Bool {
        guard activeID != profile.id else { return true }
        guard manager.fileExists(atPath: URL(fileURLWithPath: profile.codexHome).appendingPathComponent("auth.json").path) else {
            statusMessage = "Inicia sesión en \(profile.name) antes de usarla."
            return true
        }
        let previous = active
        let targetAuth = URL(fileURLWithPath: profile.codexHome, isDirectory: true).appendingPathComponent("auth.json")
        let continuationThread = automatic ? HotBridgeClient.status()?.pendingLimitThreadID : nil
        isRotationInFlight = true
        statusMessage = "Cambiando en vivo a \(profile.name)…"
        do {
            try await Task.detached(priority: .userInitiated) {
                try CodexBridge.prepareHotSwitch(home: profile.codexHome)
                _ = try HotBridgeClient.command([
                    "command": "switch",
                    "authPath": targetAuth.path,
                    "profileID": profile.id.uuidString,
                    "plan": profile.plan ?? NSNull()
                ])
            }.value
            do {
                try activateCredentials(for: profile)
            } catch {
                if let previous {
                    let previousAuth = URL(fileURLWithPath: previous.codexHome, isDirectory: true)
                        .appendingPathComponent("auth.json")
                    try? await Task.detached {
                        _ = try HotBridgeClient.command([
                            "command": "switch",
                            "authPath": previousAuth.path,
                            "profileID": previous.id.uuidString,
                            "plan": previous.plan ?? NSNull()
                        ])
                    }.value
                }
                throw error
            }
            let committedHome = sharedCodexHome.path
            let committedProfileID = profile.id.uuidString
            _ = try? await Task.detached {
                try HotBridgeClient.command([
                    "command": "commit",
                    "authHome": committedHome,
                    "profileID": committedProfileID
                ])
            }.value
            selectedID = profile.id
            bridgeCommitProfileID = profile.id
            save()
            var continuationError: Error?
            if let continuationThread {
                do {
                    _ = try await Task.detached(priority: .userInitiated) {
                        try HotBridgeClient.command([
                            "command": "continue",
                            "threadID": continuationThread
                        ])
                    }.value
                } catch {
                    continuationError = error
                }
            }
            await refresh(profile.id)
            if let continuationError {
                statusMessage = "Cuenta cambiada a \(profile.name), pero no se pudo reanudar automáticamente: \(continuationError.localizedDescription)"
            } else {
                statusMessage = automatic
                    ? "Cuenta cambiada a \(profile.name); la tarea continúa automáticamente."
                    : "Cuenta cambiada en vivo a \(profile.name)."
            }
            recordEvent(kind: automatic ? "seamless-auto" : "seamless-manual", message: statusMessage ?? "Cambio en vivo completado.")
            save()
            isRotationInFlight = false
            return true
        } catch {
            statusMessage = "El cambio en vivo no está disponible: \(error.localizedDescription). Se comprobará el modo seguro."
            recordEvent(kind: "bridge-error", message: statusMessage ?? "Falló el bridge.")
        }
        isRotationInFlight = false
        return false
    }

    private func bestAvailable(excluding id: UUID) -> AccountProfile? {
        profiles.filter { $0.id != id && $0.availableScore >= 0 }.max { $0.availableScore < $1.availableScore }
    }

    private func isGenericName(_ name: String) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "cuenta actual" || normalized == "nueva cuenta" { return true }
        return normalized.range(of: #"^cuenta\s+\d+$"#, options: .regularExpression) != nil
    }

    private func suggestedName(from email: String) -> String {
        let alias = email.split(separator: "@", maxSplits: 1).first.map(String.init) ?? email
        return alias.isEmpty ? email : alias
    }

    private func activateCredentials(for target: AccountProfile) throws {
        guard activeID != target.id else { return }
        let sharedAuth = sharedCodexHome.appendingPathComponent("auth.json")
        let targetHome = URL(fileURLWithPath: target.codexHome, isDirectory: true)
        let targetAuth = targetHome.appendingPathComponent("auth.json")
        guard manager.fileExists(atPath: targetAuth.path) else {
            throw SwitchboardError.loginFailed("inicia sesión en \(target.name) antes de usarla")
        }

        let journal = CredentialSwitchJournal(fromID: activeID, toID: target.id, phase: "prepared")
        try writeJournal(journal)
        var previousAuth: URL?
        if let current = active, manager.fileExists(atPath: sharedAuth.path) {
            let currentHome = URL(fileURLWithPath: current.codexHome, isDirectory: true)
            try secureDirectory(currentHome)
            let destination = currentHome.appendingPathComponent("auth.switch-source.json")
            if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
            let oldPrivate = currentHome.appendingPathComponent("auth.json")
            if manager.fileExists(atPath: oldPrivate.path) {
                let stale = currentHome.appendingPathComponent("auth.previous.json")
                try? manager.removeItem(at: stale)
                try manager.moveItem(at: oldPrivate, to: stale)
            }
            try manager.moveItem(at: sharedAuth, to: destination)
            previousAuth = destination
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            try writeJournal(CredentialSwitchJournal(fromID: current.id, toID: target.id, phase: "currentStored"))
        }

        do {
            try manager.moveItem(at: targetAuth, to: sharedAuth)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sharedAuth.path)
            try writeJournal(CredentialSwitchJournal(fromID: activeID, toID: target.id, phase: "targetActivated"))
            if let previousAuth, let current = active {
                let restoredPrivate = URL(fileURLWithPath: current.codexHome, isDirectory: true).appendingPathComponent("auth.json")
                try manager.moveItem(at: previousAuth, to: restoredPrivate)
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: restoredPrivate.path)
                try? manager.removeItem(at: URL(fileURLWithPath: current.codexHome, isDirectory: true).appendingPathComponent("auth.previous.json"))
            }
            activeID = target.id
            clearPendingLimit()
            waitingForCapacityAccountID = nil
            if let index = profiles.firstIndex(where: { $0.id == target.id }) {
                profiles[index].activatedAt = Date()
            }
            save()
            try? manager.removeItem(at: switchJournalFile)
        } catch {
            if manager.fileExists(atPath: sharedAuth.path), !manager.fileExists(atPath: targetAuth.path) {
                if let previousAuth, let current = active {
                    let restoredPrivate = URL(fileURLWithPath: current.codexHome, isDirectory: true).appendingPathComponent("auth.json")
                    if manager.fileExists(atPath: previousAuth.path), !manager.fileExists(atPath: restoredPrivate.path) {
                        try? manager.moveItem(at: previousAuth, to: restoredPrivate)
                    }
                }
                activeID = target.id
                clearPendingLimit()
                save()
                try? manager.removeItem(at: switchJournalFile)
                return
            }
            if let previousAuth, manager.fileExists(atPath: previousAuth.path), !manager.fileExists(atPath: sharedAuth.path) {
                try? manager.moveItem(at: previousAuth, to: sharedAuth)
            }
            try? manager.removeItem(at: switchJournalFile)
            throw error
        }
    }

    private func load() {
        do {
            try secureDirectory(support)
            try secureDirectory(profilesRoot)
            if manager.fileExists(atPath: stateFile.path) {
                let state = try JSONDecoder().decode(PersistedState.self, from: Data(contentsOf: stateFile))
                profiles = state.profiles
                selectedID = state.selectedID
                activeID = state.activeID
                automaticRotation = state.automaticRotation
                // One minute is the fallback; completed turns are refreshed
                // reactively by the thread monitor below.
                refreshMinutes = 1
                pendingLimitAccountID = state.pendingLimitAccountID
                pendingLimitDetectedAt = state.pendingLimitDetectedAt
                pendingLimitExpiresAt = state.pendingLimitExpiresAt
                events = state.events ?? []
                seamlessSwitching = state.seamlessSwitching ?? true
                windowPrimingEnabled = state.windowPrimingEnabled ?? true
                windowPrimingModel = state.windowPrimingModel ?? "gpt-5.6-luna"
                windowPrimingEffort = state.windowPrimingEffort ?? "low"
                if let activeID, let index = profiles.firstIndex(where: { $0.id == activeID }),
                   profiles[index].activatedAt == nil {
                    // Older state has no safe account-specific cutoff. Start observing
                    // failures now instead of attributing another account's old failure.
                    profiles[index].activatedAt = Date()
                    save()
                }
            } else {
                let id = UUID()
                let currentAccountHome = profilesRoot.appendingPathComponent(id.uuidString).appendingPathComponent("Account")
                try secureDirectory(currentAccountHome)
                profiles = [AccountProfile(id: id, name: "Cuenta actual", codexHome: currentAccountHome.path,
                                           browserData: profilesRoot.appendingPathComponent(id.uuidString).appendingPathComponent("Opera").path,
                                           email: nil, plan: nil, primary: nil, secondary: nil, limitReason: nil,
                                           lastChecked: nil, lastError: nil, isEnabled: true, isCurrentInstallation: true)]
                selectedID = profiles.first?.id
                activeID = profiles.first?.id
                save()
            }
            migrateLegacyCurrentProfileIfNeeded()
            migrateBrowserProfilesIfNeeded()
            recoverInterruptedCredentialSwitch()
        } catch { statusMessage = error.localizedDescription }
    }

    private func save() {
        do {
            try secureDirectory(support)
            let state = PersistedState(profiles: profiles, selectedID: selectedID, activeID: activeID,
                                       automaticRotation: automaticRotation, refreshMinutes: refreshMinutes,
                                       pendingLimitAccountID: pendingLimitAccountID,
                                       pendingLimitDetectedAt: pendingLimitDetectedAt,
                                       pendingLimitExpiresAt: pendingLimitExpiresAt,
                                       events: Array(events.prefix(40)),
                                       seamlessSwitching: seamlessSwitching,
                                       windowPrimingEnabled: windowPrimingEnabled,
                                       windowPrimingModel: windowPrimingModel,
                                       windowPrimingEffort: windowPrimingEffort)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(state).write(to: stateFile, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateFile.path)
        } catch { statusMessage = error.localizedDescription }
    }

    private func secureDirectory(_ url: URL) throws {
        try manager.createDirectory(at: url, withIntermediateDirectories: true)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func writeJournal(_ journal: CredentialSwitchJournal) throws {
        let data = try JSONEncoder().encode(journal)
        try data.write(to: switchJournalFile, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: switchJournalFile.path)
    }

    private func recoverInterruptedCredentialSwitch() {
        guard let data = try? Data(contentsOf: switchJournalFile),
              let journal = try? JSONDecoder().decode(CredentialSwitchJournal.self, from: data) else { return }
        let sharedAuth = sharedCodexHome.appendingPathComponent("auth.json")
        let from = journal.fromID.flatMap { id in profiles.first { $0.id == id } }
        let target = profiles.first { $0.id == journal.toID }
        let sourceTemp = from.map { URL(fileURLWithPath: $0.codexHome).appendingPathComponent("auth.switch-source.json") }
        let targetAuth = target.map { URL(fileURLWithPath: $0.codexHome).appendingPathComponent("auth.json") }

        if manager.fileExists(atPath: sharedAuth.path), let targetAuth, !manager.fileExists(atPath: targetAuth.path) {
            activeID = journal.toID
            if let sourceTemp, let from {
                let destination = URL(fileURLWithPath: from.codexHome).appendingPathComponent("auth.json")
                if manager.fileExists(atPath: sourceTemp.path), !manager.fileExists(atPath: destination.path) {
                    try? manager.moveItem(at: sourceTemp, to: destination)
                }
            }
            recordEvent(kind: "recovery", message: "Se completó un cambio de cuenta interrumpido con seguridad.")
        } else if !manager.fileExists(atPath: sharedAuth.path), let sourceTemp,
                  manager.fileExists(atPath: sourceTemp.path) {
            try? manager.moveItem(at: sourceTemp, to: sharedAuth)
            activeID = journal.fromID
            recordEvent(kind: "recovery", message: "Se restauró la cuenta anterior tras un cambio interrumpido.")
        }
        try? manager.removeItem(at: switchJournalFile)
        save()
    }

    private func recordEvent(kind: String, message: String) {
        events.insert(SwitchEvent(id: UUID(), date: Date(), kind: kind, message: message), at: 0)
        if events.count > 40 { events.removeLast(events.count - 40) }
    }

    private func migrateLegacyCurrentProfileIfNeeded() {
        guard let index = profiles.firstIndex(where: { $0.isCurrentInstallation && $0.codexHome == sharedCodexHome.path }) else { return }
        let accountHome = profilesRoot.appendingPathComponent(profiles[index].id.uuidString).appendingPathComponent("Account")
        do {
            try secureDirectory(accountHome)
            profiles[index].codexHome = accountHome.path
            profiles[index].browserData = profilesRoot
                .appendingPathComponent(profiles[index].id.uuidString)
                .appendingPathComponent("Opera").path
            if activeID == nil { activeID = profiles[index].id }
            save()
        } catch { statusMessage = error.localizedDescription }
    }

    private func migrateBrowserProfilesIfNeeded() {
        var changed = false
        for index in profiles.indices {
            let profileRoot = profilesRoot.appendingPathComponent(profiles[index].id.uuidString, isDirectory: true)
            let expected = profileRoot.appendingPathComponent("Opera", isDirectory: true)
            if profiles[index].browserData != expected.path {
                profiles[index].browserData = expected.path
                changed = true
            }
            do {
                try secureDirectory(profileRoot)
                try secureDirectory(expected)
                try secureDirectory(URL(fileURLWithPath: profiles[index].codexHome, isDirectory: true))
            }
            catch { statusMessage = error.localizedDescription }
        }
        if changed { save() }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshAll() }
        }
        timer?.tolerance = 1
    }

    private func scheduleLimitMonitor() {
        limitMonitorTask?.cancel()
        limitMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                await self?.checkBridgeState()
                await self?.checkUsageLimitHistory()
            }
        }
    }

    private func checkBridgeState() async {
        let detectedBridge = seamlessSwitching ? HotBridgeClient.rawStatus() : nil
        bridgeVersion = detectedBridge?.version
        let bridge = detectedBridge?.ready == true && detectedBridge?.version == HotBridgeClient.expectedVersion
            ? detectedBridge : nil
        bridgeConnected = bridge != nil
        guard let bridge else {
            bridgeCommitProfileID = nil
            return
        }
        applyBridgeRateLimits(bridge)
        if let activeID, bridgeCommitProfileID != activeID,
           bridge.activeProfileID != activeID.uuidString {
            bridgeCommitProfileID = activeID
            let home = sharedCodexHome.path
            let id = activeID.uuidString
            Task.detached(priority: .utility) {
                _ = try? HotBridgeClient.command([
                    "command": "commit", "authHome": home, "profileID": id
                ], timeout: 3)
            }
        }
        guard let limitAt = bridge.pendingLimitAt,
              lastBridgeLimitAt != limitAt,
              automaticRotation, let active else { return }
        lastBridgeLimitAt = limitAt
        if let owner = bridge.pendingLimitProfileID, owner != active.id.uuidString {
            if let ownerID = UUID(uuidString: owner) { await refresh(ownerID) }
            _ = try? await Task.detached(priority: .utility) {
                try HotBridgeClient.command(["command": "ackLimit"], timeout: 3)
            }.value
            return
        }
        pendingLimitAccountID = active.id
        pendingLimitDetectedAt = limitAt
        pendingLimitExpiresAt = limitExpiry(for: active, detectedAt: limitAt)
        save()
        await handleConfirmedLimit(for: active)
    }

    private func applyBridgeRateLimits(_ bridge: HotBridgeStatus) {
        guard let receivedAt = bridge.rateLimitsUpdatedAt,
              lastAppliedBridgeRateLimitsAt.map({ receivedAt > $0 }) ?? true,
              let limits = bridge.rateLimits,
              let activeID,
              bridge.activeProfileID == nil || bridge.activeProfileID == activeID.uuidString,
              let index = profiles.firstIndex(where: { $0.id == activeID }) else { return }
        if let primary = limits.primary { profiles[index].primary = primary.usageWindow }
        if let secondary = limits.secondary { profiles[index].secondary = secondary.usageWindow }
        profiles[index].limitReason = limits.rateLimitReachedType
            ?? (limits.spendControlReached == true ? "spend_control_reached" : nil)
        profiles[index].spendControlReached = limits.spendControlReached
        profiles[index].lastChecked = receivedAt
        profiles[index].lastAttempted = receivedAt
        profiles[index].lastError = nil
        lastAppliedBridgeRateLimitsAt = receivedAt
        save()
    }

    private func checkUsageLimitHistory() async {
        if let terminalTurnAt = latestTerminalTurnTimestamp() {
            if let previous = lastObservedTerminalTurnAt, terminalTurnAt > previous,
               !isReactiveRefreshInFlight, let active {
                isReactiveRefreshInFlight = true
                await refresh(active.id)
                isReactiveRefreshInFlight = false
            }
            lastObservedTerminalTurnAt = terminalTurnAt
        }

        guard automaticRotation, !isRotationInFlight, let active else { return }
        if waitingForCapacityAccountID == active.id {
            await handleConfirmedLimit(for: active)
            return
        }
        guard hasPendingOrRecentUsageLimit(for: active) else { return }
        await handleConfirmedLimit(for: active)
    }

    private func latestTerminalTurnTimestamp() -> Int64? {
        let database = sharedCodexHome.appendingPathComponent("thread_history_1.sqlite")
        guard manager.fileExists(atPath: database.path) else { return nil }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            "-readonly", database.path,
            "select coalesce(max(completed_at), 0) from thread_turns where status in ('completed','failed','interrupted');"
        ]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return Int64(raw)
        } catch {
            return nil
        }
    }

    private func handleConfirmedLimit(for active: AccountProfile) async {
        guard automaticRotation, !isRotationInFlight, activeID == active.id else { return }
        // Quotas can move while an account is inactive. Re-read every possible
        // destination immediately before choosing one, instead of trusting the
        // periodic snapshot used to paint the list.
        let refreshInterval: TimeInterval = waitingForCapacityAccountID == active.id ? 15 : 60
        if lastCandidateRefreshAt.map({ Date().timeIntervalSince($0) >= refreshInterval }) ?? true {
            lastCandidateRefreshAt = Date()
            for candidate in profiles where candidate.id != active.id && candidate.isEnabled && candidate.isSignedIn {
                await refresh(candidate.id)
            }
            guard automaticRotation, activeID == active.id else { return }
        }
        if waitingForCapacityAccountID == active.id,
           !active.isExhausted,
           pendingLimitAccountID != active.id {
            waitingForCapacityAccountID = nil
            statusMessage = "La cuenta activa vuelve a tener uso disponible."
            return
        }
        if hasInProgressTurn() && !(seamlessSwitching && HotBridgeClient.status() != nil) {
            statusMessage = "Hay actividad real en Codex. El cambio automático esperará; el cambio manual permite forzar."
            scheduleRotationRetry()
            return
        }
        guard let next = bestAvailable(excluding: active.id) else {
            waitingForCapacityAccountID = active.id
            statusMessage = "Todas las cuentas están agotadas. Switchboard cambiará automáticamente en cuanto alguna recupere uso."
            return
        }
        waitingForCapacityAccountID = nil
        rotationRetryTask?.cancel()
        rotationRetryTask = nil
        isRotationInFlight = true
        statusMessage = "Límite confirmado en \(active.name). Cambio automático a \(next.name)."
        await launchSingleInstance(next, automatic: true)
        isRotationInFlight = false
    }

    private var activeUsageLimitIsConfirmed: Bool {
        guard let active else { return false }
        return active.isBackendBlocked || pendingLimitAccountID == active.id
    }

    private func hasInProgressTurn() -> Bool {
        !activeTaskNames(usageLimitConfirmed: activeUsageLimitIsConfirmed).isEmpty
    }

    private func activeTaskNames(usageLimitConfirmed: Bool) -> [String] {
        let database = sharedCodexHome.appendingPathComponent("thread_history_1.sqlite")
        let stateDatabase = sharedCodexHome.appendingPathComponent("state_5.sqlite")
        guard manager.fileExists(atPath: database.path), manager.fileExists(atPath: stateDatabase.path) else {
            return ["una tarea cuyo estado no se pudo verificar"]
        }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        let escapedStatePath = stateDatabase.path.replacingOccurrences(of: "'", with: "''")
        // A terminal final answer or an explicit usage-limit error wins over a
        // stale inProgress row immediately. Once this account's usage limit is
        // confirmed, model/reasoning rows cannot make progress and only a local
        // tool whose item is genuinely inProgress remains protected.
        let activityPredicate = usageLimitConfirmed
            ? "c.has_running_item=1"
            : "(c.has_running_item=1 or c.started_at >= cast(strftime('%s','now') as integer)-20 or c.last_activity >= cast(strftime('%s','now') as integer)-45)"
        let query = """
        attach database '\(escapedStatePath)' as state_db;
        with candidates as (
          select t.thread_id, t.turn_id, t.started_at, t.error_json,
            coalesce((select max(i.created_at_ms) / 1000 from thread_items i where i.thread_id=t.thread_id and i.turn_id=t.turn_id), t.started_at, 0) as last_activity,
            coalesce((select json_extract(i.item_json, '$.phase') from thread_items i where i.thread_id=t.thread_id and i.turn_id=t.turn_id and i.item_type='agentMessage' order by i.created_at_ms desc limit 1), '') as last_agent_phase,
            exists(select 1 from thread_items i where i.thread_id=t.thread_id and i.turn_id=t.turn_id and json_extract(i.item_json, '$.status')='inProgress') as has_running_item
          from thread_turns t where t.status='inProgress'
        )
        select replace(coalesce(nullif(s.name,''), nullif(substr(s.preview,1,72),''), 'Tarea sin título'), char(9), ' ')
        from candidates c left join state_db.threads s on s.id=c.thread_id
        where c.last_agent_phase != 'final_answer'
          and coalesce(c.error_json, '') not like '%usageLimitExceeded%'
          and \(activityPredicate)
        order by c.last_activity desc;
        """
        process.arguments = [
            "-readonly", database.path,
            query
        ]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return ["una tarea cuyo estado no se pudo verificar"] }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            return (String(data: data, encoding: .utf8) ?? "")
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .filter { !$0.isEmpty }
        } catch {
            return ["una tarea cuyo estado no se pudo verificar"]
        }
    }

    private func hasPendingOrRecentUsageLimit(for active: AccountProfile) -> Bool {
        if pendingLimitAccountID == active.id {
            if let expiry = pendingLimitExpiresAt, expiry <= Date() {
                clearPendingLimit()
                save()
            } else if pendingLimitDetectedAt != nil {
                return true
            }
        } else if pendingLimitAccountID != nil {
            clearPendingLimit()
            save()
        }

        // The live bridge owns turn attribution. Falling back to the shared
        // SQLite history here would assign a late failure from the previous
        // profile to whichever profile is active now and can cause a bounce.
        if bridgeConnected { return false }

        let activation = active.activatedAt ?? Date()
        guard let failure = latestRecentUsageLimitFailure(since: activation) else { return false }
        pendingLimitAccountID = active.id
        pendingLimitDetectedAt = failure
        pendingLimitExpiresAt = limitExpiry(for: active, detectedAt: failure)
        save()
        return true
    }

    private func latestRecentUsageLimitFailure(since activation: Date) -> Date? {
        let database = sharedCodexHome.appendingPathComponent("thread_history_1.sqlite")
        guard manager.fileExists(atPath: database.path) else { return nil }
        let cutoff = max(Int(Date().timeIntervalSince1970) - 900, Int(activation.timeIntervalSince1970))
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            "-readonly", database.path,
            "select max(completed_at) from thread_turns where status='failed' and error_json like '%\"codexErrorInfo\":\"usageLimitExceeded\"%' and completed_at >= \(cutoff);"
        ]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            guard let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let timestamp = TimeInterval(raw), timestamp > 0 else { return nil }
            return Date(timeIntervalSince1970: timestamp)
        } catch {
            return nil
        }
    }

    private func limitExpiry(for active: AccountProfile, detectedAt: Date) -> Date {
        let windows = [active.primary, active.secondary].compactMap { $0 }
        let highestUsage = windows.map(\.usedPercent).max() ?? 100
        let likelyBlocking = windows.filter { $0.usedPercent == highestUsage }
        let resetDates = likelyBlocking.compactMap(\.resetsAt)
        if highestUsage >= 100, let latest = resetDates.max() { return latest }
        if let earliest = resetDates.min() { return earliest }
        return detectedAt.addingTimeInterval(24 * 60 * 60)
    }

    private func clearPendingLimit() {
        pendingLimitAccountID = nil
        pendingLimitDetectedAt = nil
        pendingLimitExpiresAt = nil
    }

    private func scheduleRotationRetry() {
        guard rotationRetryTask == nil else { return }
        rotationRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled else { return }
            self?.rotationRetryTask = nil
            await self?.refreshAll()
        }
    }
}

struct UsageMeter: View {
    let title: String
    let window: UsageWindow?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let current = window?.current(at: context.date)
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Spacer()
                    Text(current.map { "\(remaining($0))% \(L10n.text("disponible", "available"))" } ?? "—").font(.caption.monospacedDigit())
                }
                ProgressView(value: Double(current.map(remaining) ?? 0), total: 100)
                    .tint(meterColor(current))
                if let reset = current?.resetsAt {
                    Text("\(L10n.text("Se libera en", "Available in")) \(PreciseTime.remaining(until: reset, now: context.date))")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func meterColor(_ current: UsageWindow?) -> Color {
        let value = current.map(remaining) ?? 100
        if value <= 5 { return .red }
        if value <= 25 { return .orange }
        return .accentColor
    }

    private func remaining(_ value: UsageWindow) -> Int { max(0, min(100, 100 - value.usedPercent)) }

}

struct ProfileBadge: View {
    let profile: AccountProfile
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(LinearGradient(colors: badgeColors, startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(initials)
                .font(.system(size: size * 0.36, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .help(profile.email ?? profile.name)
        .accessibilityLabel("\(L10n.text("Cuenta", "Account")) \(profile.email ?? profile.name)")
    }

    private var source: String {
        if let email = profile.email, !email.isEmpty { return email.split(separator: "@").first.map(String.init) ?? email }
        return profile.name
    }

    private var initials: String {
        let parts = source
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !$0.isEmpty }
        if parts.count >= 2 {
            return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
        }
        return String((parts.first ?? source).prefix(2)).uppercased()
    }

    private var badgeColors: [Color] {
        let palettes: [[Color]] = [
            [.blue, .indigo], [.purple, .pink], [.teal, .blue], [.orange, .pink],
            [.green, .teal], [.indigo, .purple], [.cyan, .indigo], [.mint, .green]
        ]
        let index = source.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 10_007 } % palettes.count
        return palettes[index]
    }
}

struct PlanBadge: View {
    let profile: AccountProfile
    var compact = false

    var body: some View {
        Label(profile.planDisplayName, systemImage: "creditcard.fill")
            .font(compact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
            .foregroundStyle(profile.plan == nil ? .secondary : .primary)
            .padding(.horizontal, compact ? 7 : 9)
            .padding(.vertical, compact ? 3 : 4)
            .background(.quaternary, in: Capsule())
            .lineLimit(1)
            .help("Plan detectado por Codex: \(profile.planDisplayName)")
    }
}

struct AccountRow: View {
    let profile: AccountProfile
    let isActive: Bool

    var body: some View {
        HStack(spacing: 12) {
            ProfileBadge(profile: profile)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(profile.name).font(.headline).lineLimit(1).layoutPriority(2)
                    if isActive { Circle().fill(.green).frame(width: 7, height: 7).help(L10n.text("Cuenta activa", "Active account")) }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 6) {
                    Text(profile.email ?? (profile.lastError == nil ? L10n.text("Sin conectar", "Not connected") : L10n.text("No disponible", "Unavailable")))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 6)
                    PlanBadge(profile: profile, compact: true)
                }
                HStack(spacing: 6) {
                    Text(storeStatus)
                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    Spacer(minLength: 0)
                }
                if profile.hasReliableQuota, !profile.isExhausted {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(windowSummary("5 h", window: profile.currentPrimary, now: context.date))
                            Text(windowSummary(L10n.text("S", "W"), window: profile.currentSecondary, now: context.date))
                        }
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                }
            }
            if profile.isExhausted {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            }
        }.padding(.vertical, 5)
    }

    private var storeStatus: String {
        if isActive { return L10n.text("Activa en Codex", "Active in Codex") }
        if profile.lastError != nil { return "Dato anterior · error al actualizar" }
        if !profile.isEnabled { return "Fuera del cambio automático" }
        if profile.isExhausted { return L10n.text("Sin uso disponible", "No usage available") }
        return L10n.text("Disponible", "Available")
    }

    private func windowSummary(_ title: String, window: UsageWindow?, now: Date) -> String {
        guard let window else { return "\(title) —" }
        let current = window.current(at: now)
        let remaining = max(0, 100 - current.usedPercent)
        guard let reset = current.resetsAt else { return "\(title) \(remaining)%" }
        return "\(title) \(remaining)% · \(PreciseTime.remaining(until: reset, now: now))"
    }
}

struct DetailView: View {
    @ObservedObject var store: SwitchboardStore
    let profile: AccountProfile
    @State private var renameText = ""
    @State private var showingRename = false
    @State private var showingDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if profile.isSignedIn { usageCard } else { connectCard }
                if profile.isSignedIn { automationCard }
                diagnosticsCard
                accountActions
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItemGroup {
                Button { Task { await store.refresh(profile.id) } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Actualizar cuota")
                Menu { accountMenu } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .alert("Renombrar cuenta", isPresented: $showingRename) {
            TextField("Nombre", text: $renameText)
            Button("Cancelar", role: .cancel) {}
            Button("Guardar") { store.rename(profile, to: renameText) }
        }
        .alert("Eliminar cuenta", isPresented: $showingDelete) {
            Button("Cancelar", role: .cancel) {}
            Button("Eliminar", role: .destructive) { store.delete(profile) }
        } message: {
            Text("La carpeta de esta cuenta, incluida su sesión local, se moverá a la Papelera. Las conversaciones compartidas de Codex no se borrarán.")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            ProfileBadge(profile: profile, size: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(profile.name).font(.system(size: 28, weight: .bold, design: .rounded))
                HStack(spacing: 8) {
                    PlanBadge(profile: profile)
                    if store.activeID == profile.id {
                        Label(L10n.text("En Codex", "In Codex"), systemImage: "circle.fill").font(.caption).foregroundStyle(.green)
                    }
                }
                if let email = profile.email { Text(email).font(.subheadline).foregroundStyle(.secondary) }
            }
            Spacer()
            Button { store.launch(profile) } label: { Label("Usar en Codex", systemImage: "arrow.up.forward.app.fill") }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(!profile.isSignedIn)
        }
    }

    private var usageCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(usageTitle, systemImage: usageIcon)
                    .font(.title3.weight(.semibold)).foregroundStyle(profile.lastError != nil ? .orange : (profile.isExhausted ? .red : .primary))
                Spacer()
                VStack(alignment: .trailing, spacing: 7) {
                    Button { store.requestPlanManagement(profile) } label: {
                        Label("Gestionar plan en Opera", systemImage: "shield.lefthalf.filled")
                    }
                    .buttonStyle(.bordered)
                    if let date = profile.lastChecked {
                        Text("\(L10n.text("Actualizado", "Updated")) \(relativeSpanish(date))").font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            UsageMeter(title: L10n.text("VENTANA CORTA", "SHORT WINDOW"), window: profile.currentPrimary)
            UsageMeter(title: L10n.text("VENTANA SEMANAL", "WEEKLY WINDOW"), window: profile.currentSecondary)
            if let credits = profile.resetCreditsAvailable, credits > 0 {
                Label("\(credits) reinicio\(credits == 1 ? "" : "s") de límite disponible\(credits == 1 ? "" : "s") en Codex", systemImage: "arrow.counterclockwise.circle.fill")
                    .font(.caption).foregroundStyle(.blue)
            }
            if profile.isBackendBlocked, let reason = profile.limitReason {
                Text(reason.replacingOccurrences(of: "_", with: " ")).font(.caption).foregroundStyle(.red)
            }
            if let error = profile.lastError {
                Label("No se pudo actualizar: \(error)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                if let date = profile.lastChecked {
                    Text("Se conserva el último dato válido de \(relativeSpanish(date)). Esta cuenta no se usará como destino automático hasta verificarla.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }.cardStyle()
    }

    private var usageTitle: String {
        if profile.lastError != nil { return L10n.text("Último dato válido", "Last valid data") }
        return profile.isExhausted ? L10n.text("Uso agotado", "Usage exhausted") : L10n.text("Uso disponible", "Usage available")
    }

    private var usageIcon: String {
        if profile.lastError != nil { return "exclamationmark.triangle.fill" }
        return profile.isExhausted ? "bolt.slash.fill" : "bolt.fill"
    }

    private var automationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Cambio automático", systemImage: "arrow.triangle.2.circlepath")
                    .font(.headline)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { profile.isEnabled },
                    set: { store.setRotationEnabled($0, for: profile) }
                )).labelsHidden()
            }
            Text(profile.isEnabled
                 ? "Esta cuenta puede ser elegida cuando otra se quede sin uso."
                 : "Esta cuenta nunca se elegirá automáticamente; el cambio manual sigue disponible.")
                .font(.callout).foregroundStyle(.secondary)
            if store.activeID == profile.id, let next = store.recommendedNext {
                Label("\(L10n.text("Siguiente opción", "Next option")): \(next.name) · 5 h \(next.shortRemaining.map(String.init) ?? "—")% · \(L10n.text("semana", "week")) \(next.weeklyRemaining.map(String.init) ?? "—")%", systemImage: "sparkles")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if store.activeID == profile.id {
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Label("Cambio sin cerrar Codex", systemImage: "bolt.horizontal.circle")
                            .font(.subheadline.weight(.semibold))
                        Text(store.bridgeConnected
                             ? "Bridge conectado · las tareas pueden continuar entre cuentas."
                             : store.bridgeVersion != nil
                                ? "Hay una versión anterior del bridge activa · reinicia Codex para cargar la corrección instalada."
                                : "Se activará en el próximo inicio gestionado de Codex.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { store.seamlessSwitching },
                        set: store.setSeamlessSwitching
                    )).labelsHidden()
                }
            }
            Divider()
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Preparar ventanas de 5 h", systemImage: "timer")
                        .font(.subheadline.weight(.semibold))
                    Text("Reduce la espera iniciando la recuperación de las cuentas disponibles.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 20)
                Toggle("", isOn: Binding(
                    get: { store.windowPrimingEnabled },
                    set: store.setWindowPrimingEnabled
                )).labelsHidden()
            }
            if store.windowPrimingEnabled {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                    GridRow {
                        Text("Modelo").font(.caption).foregroundStyle(.secondary)
                        Picker("Modelo", selection: Binding(
                            get: { store.windowPrimingModel },
                            set: store.setWindowPrimingModel
                        )) {
                            ForEach(store.primingModels.isEmpty
                                    ? [PrimingModelOption(id: store.windowPrimingModel,
                                                         displayName: store.windowPrimingModel,
                                                         efforts: [store.windowPrimingEffort])]
                                    : store.primingModels) { model in
                                Text(model.displayName).tag(model.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 260)
                    }
                    GridRow {
                        Text("Razonamiento").font(.caption).foregroundStyle(.secondary)
                        Picker("Razonamiento", selection: Binding(
                            get: { store.windowPrimingEffort },
                            set: store.setWindowPrimingEffort
                        )) {
                            ForEach(store.primingEfforts, id: \.self) { effort in
                                Text(effort.capitalized).tag(effort)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 260)
                    }
                }
                Button("Actualizar modelos") { Task { await store.refreshPrimingModels() } }
                    .buttonStyle(.link)
                    .font(.caption)
                if let record = store.windowPrimingRecord(for: profile) {
                    Label(primingStatus(record), systemImage: record.status == "error"
                          ? "exclamationmark.triangle.fill" : "clock.badge.checkmark")
                        .font(.caption)
                        .foregroundStyle(record.status == "error" ? .orange : .secondary)
                }
            }
        }.cardStyle()
    }

    private func primingStatus(_ record: WindowPrimingRecord) -> String {
        if let error = record.error { return L10n.text("Preparación: \(error)", "Preparation: \(error)") }
        let reset: String
        if let date = record.resetAt, date > Date() {
            reset = " · " + L10n.text("reinicia en \(PreciseTime.remaining(until: date))", "resets in \(PreciseTime.remaining(until: date))")
        } else if record.resetAt != nil {
            reset = L10n.text(" · pendiente de comprobación", " · awaiting check")
        } else {
            reset = ""
        }
        switch record.status {
        case "anchored": return L10n.text("Ventana preparada con \(record.model) / \(record.effort)\(reset)", "Window prepared with \(record.model) / \(record.effort)\(reset)")
        case "already-anchored": return L10n.text("Ventana ya iniciada\(reset)", "Window already started\(reset)")
        case "window-in-use": return L10n.text("Ventana actualmente en uso\(reset)", "Window currently in use\(reset)")
        case "window-opened-elsewhere": return L10n.text("Otra tarea inició la ventana\(reset)", "Another task started the window\(reset)")
        case "fully-blocked": return L10n.text("La cuenta está completamente bloqueada\(reset)", "The account is fully blocked\(reset)")
        default: return L10n.text("Comprobada \(relativeSpanish(record.checkedAt))\(reset)", "Checked \(relativeSpanish(record.checkedAt))\(reset)")
        }
    }

    private var diagnosticsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Estado técnico", systemImage: "checkmark.shield.fill").font(.headline)
            HStack {
                Text("Codex local")
                Spacer()
                Text(integrationDisplay)
                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack {
                Text("Cambio en vivo")
                Spacer()
                Label(store.bridgeConnected ? "Conectado" : store.bridgeVersion != nil ? "Reinicio necesario" : "En espera",
                      systemImage: store.bridgeConnected ? "checkmark.circle.fill" : store.bridgeVersion != nil ? "arrow.clockwise.circle" : "clock")
                    .font(.caption)
                    .foregroundStyle(store.bridgeConnected ? .green : .secondary)
            }
            if let event = store.events.first {
                Divider()
                Text("Actividad reciente").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(localizedEventMessage(event)).font(.callout)
                Text(relativeSpanish(event.date)).font(.caption2).foregroundStyle(.tertiary)
            }
        }.cardStyle()
    }

    private var integrationDisplay: String {
        guard let raw = store.integrationVersion else { return L10n.text("Comprobando…", "Checking…") }
        let first = raw.split(separator: " ").first.map(String.init) ?? raw
        if let slash = first.firstIndex(of: "/") {
            return "Codex " + first[first.index(after: slash)...]
        }
        return first
    }

    private func localizedEventMessage(_ event: SwitchEvent) -> String {
        guard L10n.isEnglish else { return event.message }
        switch event.kind {
        case "automatic": return "Automatic account switch completed."
        case "manual": return "Account switch completed."
        case "recovery": return "Account state recovered."
        default: return "Switchboard status updated."
        }
    }

    private func relativeSpanish(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: L10n.isEnglish ? "en_US" : "es_ES")
        formatter.dateTimeStyle = .numeric
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private var connectCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Conecta esta cuenta", systemImage: "person.crop.circle.badge.plus").font(.title3.weight(.semibold))
            Text("El acceso se completa en la página oficial. Switchboard no ve, copia ni exporta tus tokens.")
                .foregroundStyle(.secondary)
            Button("Iniciar sesión con ChatGPT") { store.signIn(profile) }.buttonStyle(.borderedProminent)
            if let error = profile.lastError { Text(error).font(.caption).foregroundStyle(.red) }
        }.cardStyle()
    }

    private var accountActions: some View {
        HStack(spacing: 12) {
            if profile.isSignedIn {
                Button("Cerrar sesión") { store.signOut(profile) }
                    .buttonStyle(.bordered)
            }
            Spacer()
            Button("Eliminar cuenta", role: .destructive) { showingDelete = true }
                .buttonStyle(.bordered)
                .disabled(store.activeID == profile.id)
                .help(store.activeID == profile.id
                      ? L10n.text("Cambia primero a otra cuenta", "Switch to another account first")
                      : L10n.text("Mover la sesión local de esta cuenta a la Papelera", "Move this account's local session to Trash"))
        }
    }

    @ViewBuilder private var accountMenu: some View {
        Button("Renombrar") { renameText = profile.name; showingRename = true }
        Button("Gestionar plan en Opera…") { store.requestPlanManagement(profile) }
            .disabled(!profile.isSignedIn)
        Button("Abrir carpeta del perfil") { store.openProfileFolder(profile) }
        Divider()
        if profile.isSignedIn { Button("Cerrar sesión") { store.signOut(profile) } }
        else { Button("Iniciar sesión") { store.signIn(profile) } }
        Divider()
        Button("Eliminar cuenta", role: .destructive) { showingDelete = true }
            .disabled(store.activeID == profile.id)
    }
}

private extension View {
    func cardStyle() -> some View {
        self.padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.separator.opacity(0.35)))
    }
}

struct ContentView: View {
    @ObservedObject var store: SwitchboardStore
    @State private var showingAdd = false
    @State private var newName = "Cuenta 2"

    var body: some View {
        VStack(spacing: 0) {
            if let message = store.statusMessage {
                StatusBanner(message: message) { store.statusMessage = nil }
                Divider()
            }
            NavigationSplitView {
            List(selection: $store.selectedID) {
                Section("CUENTAS") {
                    ForEach(store.profiles) { profile in
                        AccountRow(profile: profile, isActive: store.activeID == profile.id).tag(profile.id)
                    }
                }
            }
            .navigationTitle("Switchboard")
            .navigationSplitViewColumnWidth(min: 300, ideal: 330, max: 380)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    Divider()
                    Toggle(isOn: Binding(get: { store.automaticRotation }, set: store.setAutomaticRotation)) {
                        Label("Cambio automático", systemImage: "wand.and.stars")
                    }.toggleStyle(.switch).fixedSize(horizontal: false, vertical: true)
                    Button { newName = "Cuenta \(store.profiles.count + 1)"; showingAdd = true } label: {
                        Label("Añadir cuenta", systemImage: "plus").frame(maxWidth: .infinity)
                    }.buttonStyle(.bordered)
                }.padding(14).background(.bar)
            }
            } detail: {
            if let profile = store.selected {
                DetailView(store: store, profile: profile)
            } else {
                ContentUnavailableView("Selecciona una cuenta", systemImage: "person.2")
            }
            }
        }
        .frame(minWidth: 980, minHeight: 620)
        .alert("Nueva cuenta", isPresented: $showingAdd) {
            TextField("Nombre", text: $newName)
            Button("Cancelar", role: .cancel) {}
            Button("Crear") { store.addProfile(name: newName) }
        } message: { Text("Después podrás iniciar sesión de forma independiente.") }
        .alert("Activar cambio automático", isPresented: $store.showingAutoRotationWarning) {
            Button("Cancelar", role: .cancel) {}
            Button("Activar") { store.confirmAutomaticRotation() }
        } message: {
            Text(store.seamlessSwitching
                 ? "Cuando el bridge esté conectado, Switchboard cambiará la autenticación en memoria y continuará la tarea sin cerrar Codex. Si una actualización rompe la compatibilidad, volverá al cierre seguro y nunca forzará una tarea activa."
                 : "Cuando una cuenta se agote, Switchboard esperará a que no haya trabajo activo, cerrará Codex y lo abrirá con otra cuenta.")
        }
        .alert("Hay actividad en Codex", isPresented: $store.showingForceSwitchWarning) {
            Button("Cancelar", role: .cancel) { store.cancelForcedSwitch() }
            Button("Forzar cambio", role: .destructive) { store.confirmForcedSwitch() }
        } message: {
            Text(store.forceSwitchMessage)
        }
    }
}

struct StatusBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle.fill").foregroundStyle(.blue)
            Text(message).font(.callout).lineLimit(2)
            Spacer(minLength: 12)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Cerrar")
        }
        .padding(.horizontal, 18).padding(.vertical, 11)
        .background(.bar)
    }
}

enum OperaPlanError: LocalizedError {
    case missing
    case launch(String)

    var errorDescription: String? {
        switch self {
        case .missing: return "Opera no está instalado en /Applications/Opera.app."
        case .launch(let message): return "No se pudo abrir el perfil aislado de Opera: \(message)"
        }
    }
}

enum OperaPlanStage {
    case vpnSetup
    case billing
}

enum OperaPlanSession {
    private static let executable = "/Applications/Opera.app/Contents/MacOS/Opera"

    static func open(profile: AccountProfile) throws -> OperaPlanStage {
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw OperaPlanError.missing }
        let root = URL(fileURLWithPath: profile.browserData, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        if !vpnOptionReady(in: root) { try prepareVPNOption(in: root) }

        let enabled = vpnEnabled(in: root)
        if !enabled {
            try launch(root: root, destination: "opera://settings/?search=VPN")
            return .vpnSetup
        }
        try launch(root: root, destination: billingBridgeURL)
        return .billing
    }

    private static func launch(root: URL, destination: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        let arguments = [
            "--user-data-dir=\(root.path)",
            "--no-first-run",
            "--no-default-browser-check",
            destination,
        ]
        process.arguments = arguments
        do {
            try process.run()
            Thread.sleep(forTimeInterval: 0.35)
            activateOpera(using: root)
        }
        catch { throw OperaPlanError.launch(error.localizedDescription) }
    }

    private static func vpnEnabled(in root: URL) -> Bool {
        let preferences = root.appendingPathComponent("Default/Preferences")
        guard let data = try? Data(contentsOf: preferences),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let freedom = object["freedom"] as? [String: Any],
              let switcher = freedom["proxy_switcher"] as? [String: Any]
        else { return false }
        return switcher["enabled"] as? Bool == true
    }

    private static var billingBridgeURL: String {
        "https://chatgpt.com/#settings/Billing"
    }

    private static func vpnOptionReady(in root: URL) -> Bool {
        let preferences = root.appendingPathComponent("Default/Preferences")
        guard let data = try? Data(contentsOf: preferences),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        let migrated = (object["vpn_pro"] as? [String: Any])?["migrated_to_v4"] as? Bool == true
        let switcher = (object["freedom"] as? [String: Any])?["proxy_switcher"] as? [String: Any]
        return switcher?["enabled"] as? Bool == true || (migrated && switcher?["ui_visible"] as? Bool == true)
    }

    private static func prepareVPNOption(in root: URL) throws {
        terminateOpera(using: root)
        let defaultFolder = root.appendingPathComponent("Default", isDirectory: true)
        try FileManager.default.createDirectory(at: defaultFolder, withIntermediateDirectories: true)
        let preferences = defaultFolder.appendingPathComponent("Preferences")
        var object: [String: Any] = [:]
        if let data = try? Data(contentsOf: preferences),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object = existing
        }
        var vpnPro = object["vpn_pro"] as? [String: Any] ?? [:]
        vpnPro["migrated_to_v4"] = true
        object["vpn_pro"] = vpnPro

        var freedom = object["freedom"] as? [String: Any] ?? [:]
        var switcher = freedom["proxy_switcher"] as? [String: Any] ?? [:]
        switcher["forbidden"] = false
        switcher["ui_visible"] = true
        freedom["proxy_switcher"] = switcher
        object["freedom"] = freedom

        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: preferences, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: preferences.path)
    }

    private static func terminateOpera(using root: URL) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,command="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        // Drain before waiting: a long process list can fill the pipe and deadlock
        // both ps and Switchboard if the parent waits without reading.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        let marker = "/Applications/Opera.app/Contents/MacOS/Opera --user-data-dir=\(root.path)"
        for line in text.split(separator: "\n") where line.contains(marker) {
            guard let token = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).first,
                  let pid = pid_t(token) else { continue }
            _ = NSRunningApplication(processIdentifier: pid)?.terminate()
        }
    }

    private static func activateOpera(using root: URL) {
        let marker = "/Applications/Opera.app/Contents/MacOS/Opera --user-data-dir=\(root.path)"
        for _ in 0..<10 {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/ps")
            process.arguments = ["-axo", "pid=,command="]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(data: data, encoding: .utf8) ?? ""
            for line in text.split(separator: "\n") where line.contains(marker) {
                guard let token = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).first,
                      let pid = pid_t(token),
                      let app = NSRunningApplication(processIdentifier: pid) else { continue }
                app.activate(options: [.activateAllWindows])
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private static func waitForOperaToExit(using root: URL) {
        let marker = "/Applications/Opera.app/Contents/MacOS/Opera --user-data-dir=\(root.path)"
        for _ in 0..<30 {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/ps")
            process.arguments = ["-axo", "command="]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(data: data, encoding: .utf8) ?? ""
            if !text.contains(marker) { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
}

@MainActor
final class ManagerWindowController: NSObject, NSWindowDelegate {
    static let shared = ManagerWindowController()
    private var window: NSWindow?

    func show(store: SwitchboardStore) {
        if window == nil {
            let controller = NSHostingController(rootView: ContentView(store: store))
            let created = NSWindow(contentViewController: controller)
            created.title = ""
            created.setContentSize(NSSize(width: 1120, height: 760))
            created.minSize = NSSize(width: 980, height: 620)
            created.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            created.titlebarAppearsTransparent = false
            created.titleVisibility = .hidden
            created.isReleasedWhenClosed = false
            created.setFrameAutosaveName("CodexSwitchboardManager")
            created.delegate = self
            window = created
        }
        normalizeWindowFrame()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if let active = store.active {
            Task { await store.refresh(active.id) }
        }
    }

    private func normalizeWindowFrame() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = window.frame
        frame.size.width = min(max(frame.width, window.minSize.width), visible.width)
        frame.size.height = min(max(frame.height, window.minSize.height), visible.height)
        frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        window.setFrame(frame, display: false)
    }
}

final class LifecycleDelegate: NSObject, NSApplicationDelegate {
    static weak var store: SwitchboardStore?
    private var terminationObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.openai.codex" else { return }
            Task { @MainActor in
                if !LifecycleCoordinator.shared.managedCodexRestart { NSApp.terminate(nil) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            Task { @MainActor in
                let codexRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").isEmpty
                if !codexRunning && !LifecycleCoordinator.shared.managedCodexRestart { NSApp.terminate(nil) }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let terminationObserver { NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let store = Self.store { ManagerWindowController.shared.show(store: store) }
        return true
    }
}

enum MenuBarIcon {
    static let image: NSImage = {
        let configuration = NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        let image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Codex Switchboard")?
            .withSymbolConfiguration(configuration) ?? NSImage()
        image.isTemplate = true
        return image
    }()
}

@main
struct CodexSwitchboardApp: App {
    @NSApplicationDelegateAdaptor(LifecycleDelegate.self) private var lifecycleDelegate
    @StateObject private var store: SwitchboardStore

    init() {
        let createdStore = SwitchboardStore()
        _store = StateObject(wrappedValue: createdStore)
        LifecycleDelegate.store = createdStore
    }

    var body: some Scene {
        MenuBarExtra {
            Button("Abrir gestor") { ManagerWindowController.shared.show(store: store) }
                .keyboardShortcut("g")
            Divider()
            if let active = store.active {
                Text("Activa: \(active.email ?? active.name) · \(active.planDisplayName)")
                Divider()
                quotaMenuLine("5 horas", window: active.currentPrimary)
                quotaMenuLine("Semanal", window: active.currentSecondary)
                if let next = store.recommendedNext {
                    Text("Siguiente automática: \(next.name)")
                }
                Button("Gestionar plan de \(active.name) en Opera…") {
                    store.requestPlanManagement(active)
                }
                .disabled(!active.isSignedIn)
            } else {
                Text("Sin cuenta activa")
            }
            Menu("Cuentas") {
                ForEach(store.profiles) { profile in
                    Button {
                        store.selectedID = profile.id
                        ManagerWindowController.shared.show(store: store)
                    } label: {
                        Text(menuAccountLine(profile))
                    }
                }
            }
            Divider()
            Button(store.isRefreshing ? "Actualizando…" : "Actualizar cuotas") {
                Task { await store.refreshAll() }
            }.disabled(store.isRefreshing)
            Toggle("Cambio automático", isOn: Binding(get: { store.automaticRotation }, set: store.setAutomaticRotation))
            Divider()
            SettingsLink { Text("Ajustes…") }
            Button("Cerrar Codex y Switchboard") {
                NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").forEach { _ = $0.terminate() }
            }
        } label: {
            Image(nsImage: MenuBarIcon.image)
                .accessibilityLabel("Codex Switchboard")
        }
        Settings { SettingsView() }
    }

    @ViewBuilder
    private func quotaMenuLine(_ title: String, window: UsageWindow?) -> some View {
        if let window {
            let now = Date()
            let current = window.current(at: now)
            let remaining = max(0, 100 - current.usedPercent)
            if let reset = current.resetsAt {
                Text("\(title): \(remaining)% \(L10n.text("disponible", "available")) · \(PreciseTime.remaining(until: reset, now: now))")
            } else {
                Text("\(title): \(remaining)% \(L10n.text("disponible", "available"))")
            }
        } else {
            Text("\(title): \(L10n.text("sin datos", "no data"))")
        }
    }

    private func menuAccountLine(_ profile: AccountProfile) -> String {
        let short = profile.shortRemaining.map(String.init) ?? "—"
        let week = profile.weeklyRemaining.map(String.init) ?? "—"
        let warning = profile.lastError == nil ? "" : L10n.text(" · dato anterior", " · previous data")
        return "\(profile.name) · \(profile.planDisplayName) · 5 h \(short)% · \(L10n.text("semana", "week")) \(week)%\(warning)"
    }
}

struct SettingsView: View {
    var body: some View {
        Form {
            Section("Privacidad") {
                Label("Los perfiles viven en Application Support con permisos 0700.", systemImage: "lock.fill")
                Text("Switchboard nunca muestra el contenido de auth.json. Con Codex cerrado, mueve atómicamente el archivo entre almacenes privados para activar la cuenta elegida.")
                    .foregroundStyle(.secondary)
            }
            Section("Compatibilidad") {
                Text("Si OpenAI cambia el protocolo de cuenta o límites, el monitor mostrará un error y no intentará modificar credenciales.")
                    .foregroundStyle(.secondary)
            }
        }.padding(24).frame(width: 520)
    }
}
