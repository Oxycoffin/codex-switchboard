import AppKit
import Foundation

private struct PulseProfile: Decodable {
    let id: UUID
    let codexHome: String
    let email: String?
    let isEnabled: Bool
}

private struct PulseState: Decodable {
    let profiles: [PulseProfile]
    let activeID: UUID?
    let windowPrimingEnabled: Bool?
    let windowPrimingModel: String?
    let windowPrimingEffort: String?
}

private struct PrimingRecord: Codable {
    var email: String
    var checkedAt: Date
    var anchoredAt: Date?
    var resetAt: Date?
    var model: String
    var effort: String
    var status: String
    var error: String?
}

private struct PrimingLedger: Codable {
    var updatedAt = Date()
    var accounts: [String: PrimingRecord] = [:]
}

private struct RateSnapshot {
    let shortUsed: Int?
    let shortReset: Date?
    let weeklyUsed: Int?
    let blocked: Bool
}

private enum PrimingError: LocalizedError {
    case codexMissing
    case invalidResponse(String)
    case sessionMissing(String)

    var errorDescription: String? {
        switch self {
        case .codexMissing: return "No se encontró el binario local de Codex."
        case .invalidResponse(let value): return "Respuesta no válida de Codex: \(value)"
        case .sessionMissing(let email): return "No se encontró una sesión aislada para \(email)."
        }
    }
}

private final class PrimingAppServer {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var nextID = 1
    private var notifications: [[String: Any]] = []

    init(home: URL) throws {
        let binary = "/Applications/ChatGPT.app/Contents/Resources/codex"
        guard FileManager.default.isExecutableFile(atPath: binary) else { throw PrimingError.codexMissing }
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["app-server", "--stdio"]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = home.path
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        _ = try request(method: "initialize", params: [
            "clientInfo": ["name": "codex-switchboard-window-primer", "title": "Window primer", "version": "1.0.0"],
            "capabilities": ["experimentalApi": true]
        ], timeout: 15)
        try write(["method": "initialized", "params": [:]])
    }

    deinit { stop() }

    func stop() {
        if process.isRunning { process.terminate() }
    }

    func request(method: String, params: Any? = nil, timeout: TimeInterval = 30) throws -> [String: Any] {
        let id = nextID
        nextID += 1
        var message: [String: Any] = ["id": id, "method": method]
        if let params { message["params"] = params }
        try write(message)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let response = try read(deadline: deadline)
            if response["method"] != nil {
                notifications.append(response)
                continue
            }
            if (response["id"] as? Int) == id {
                if let error = response["error"] as? [String: Any] {
                    throw PrimingError.invalidResponse(error["message"] as? String ?? "error RPC")
                }
                return response["result"] as? [String: Any] ?? [:]
            }
        }
        throw PrimingError.invalidResponse("tiempo de espera agotado para \(method)")
    }

    func waitForNotification(method: String, threadID: String, turnID: String, timeout: TimeInterval) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let index = notifications.firstIndex(where: { matches($0, method: method, threadID: threadID, turnID: turnID) }) {
                return notifications.remove(at: index)["params"] as? [String: Any] ?? [:]
            }
            let message = try read(deadline: deadline)
            if matches(message, method: method, threadID: threadID, turnID: turnID) {
                return message["params"] as? [String: Any] ?? [:]
            }
            if message["method"] != nil { notifications.append(message) }
        }
        throw PrimingError.invalidResponse("la interacción mínima no terminó a tiempo")
    }

    private func matches(_ message: [String: Any], method: String, threadID: String, turnID: String) -> Bool {
        guard message["method"] as? String == method,
              let params = message["params"] as? [String: Any],
              params["threadId"] as? String == threadID,
              let turn = params["turn"] as? [String: Any] else { return false }
        return turn["id"] as? String == turnID
    }

    private func write(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    private func read(deadline: Date) throws -> [String: Any] {
        while Date() < deadline {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                if !line.isEmpty,
                   let value = try JSONSerialization.jsonObject(with: line) as? [String: Any] { return value }
            }
            let data = output.fileHandleForReading.availableData
            if data.isEmpty { throw PrimingError.invalidResponse("el servidor local terminó") }
            buffer.append(data)
        }
        throw PrimingError.invalidResponse("tiempo de espera agotado")
    }
}

private final class WindowPrimingCoordinator {
    private let manager = FileManager.default
    private let queue = DispatchQueue(label: "local.codex.switchboard.window-priming", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var wakeObserver: NSObjectProtocol?
    private let support: URL
    private let stateFile: URL
    private let ledgerFile: URL
    private let sharedAuth: URL

    init() {
        support = manager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Codex Switchboard", isDirectory: true)
        stateFile = support.appendingPathComponent("state.json")
        ledgerFile = support.appendingPathComponent("window-priming-state.json")
        sharedAuth = manager.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 8, repeating: 60, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in self?.run() }
        timer.resume()
        self.timer = timer
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in self?.queue.async { self?.run() } }
    }

    private func run() {
        guard let data = try? Data(contentsOf: stateFile),
              let state = try? JSONDecoder().decode(PulseState.self, from: data),
              state.windowPrimingEnabled ?? false else { return }
        let model = normalized(state.windowPrimingModel) ?? "gpt-5.6-luna"
        let effort = normalized(state.windowPrimingEffort) ?? "low"
        var ledger = loadLedger()
        let codexRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").isEmpty

        for profile in state.profiles where profile.isEnabled {
            guard let email = normalized(profile.email) else { continue }
            if codexRunning && profile.id == state.activeID { continue }
            do {
                try consider(profile: profile, email: email, allProfiles: state.profiles,
                             model: model, effort: effort, ledger: &ledger)
            } catch {
                ledger.accounts[profile.id.uuidString] = PrimingRecord(
                    email: email, checkedAt: Date(), anchoredAt: ledger.accounts[profile.id.uuidString]?.anchoredAt,
                    resetAt: ledger.accounts[profile.id.uuidString]?.resetAt,
                    model: model, effort: effort, status: "error", error: error.localizedDescription
                )
                saveLedger(&ledger)
            }
        }
    }

    private func consider(profile: PulseProfile, email: String, allProfiles: [PulseProfile],
                          model: String, effort: String, ledger: inout PrimingLedger) throws {
        if let reset = ledger.accounts[profile.id.uuidString]?.resetAt, reset > Date().addingTimeInterval(30) {
            return
        }
        let auth = try resolveAuth(email: email, profiles: allProfiles)
        let temporaryRoot = manager.temporaryDirectory.appendingPathComponent("codex-window-primer.\(UUID().uuidString)", isDirectory: true)
        let home = temporaryRoot.appendingPathComponent("home", isDirectory: true)
        defer { try? manager.removeItem(at: temporaryRoot) }
        try manager.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let copiedAuth = home.appendingPathComponent("auth.json")
        try manager.copyItem(at: auth, to: copiedAuth)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copiedAuth.path)

        let server = try PrimingAppServer(home: home)
        defer { server.stop() }
        try validate(model: model, effort: effort, server: server)
        let account = try server.request(method: "account/read", params: ["refreshToken": false])
        let actualEmail = ((account["account"] as? [String: Any])?["email"] as? String) ?? ""
        guard actualEmail.caseInsensitiveCompare(email) == .orderedSame else {
            throw PrimingError.sessionMissing(email)
        }

        let firstReadAt = Date()
        let first = try rateSnapshot(server)
        guard let firstShortUsed = first.shortUsed else {
            record(profile, email: email, model: model, effort: effort, status: "not-supported",
                   resetAt: nil, ledger: &ledger)
            return
        }
        guard firstShortUsed == 0 else {
            record(profile, email: email, model: model, effort: effort, status: "window-in-use",
                   resetAt: first.shortReset, ledger: &ledger)
            return
        }
        guard first.weeklyUsed != 100, !first.blocked else {
            record(profile, email: email, model: model, effort: effort, status: "fully-blocked",
                   resetAt: first.shortReset, ledger: &ledger)
            return
        }

        Thread.sleep(forTimeInterval: 3.2)
        let secondReadAt = Date()
        let second = try rateSnapshot(server)
        guard second.shortUsed == 0 else {
            record(profile, email: email, model: model, effort: effort, status: "window-opened-elsewhere",
                   resetAt: second.shortReset, ledger: &ledger)
            return
        }
        guard isMovingCleanWindow(first: first, firstReadAt: firstReadAt,
                                  second: second, secondReadAt: secondReadAt) else {
            record(profile, email: email, model: model, effort: effort, status: "already-anchored",
                   resetAt: second.shortReset, ledger: &ledger)
            return
        }

        let started = Date()
        let thread = try server.request(method: "thread/start", params: [
            "cwd": temporaryRoot.path,
            "model": model,
            "ephemeral": true,
            "approvalPolicy": "never",
            "sandbox": "read-only",
            "developerInstructions": "Return only the literal text OK. Do not call tools."
        ])
        guard let threadID = (thread["thread"] as? [String: Any])?["id"] as? String else {
            throw PrimingError.invalidResponse("thread/start no devolvió un identificador")
        }
        let turn = try server.request(method: "turn/start", params: [
            "threadId": threadID,
            "model": model,
            "effort": effort,
            "input": [["type": "text", "text": "Reply exactly OK."]],
            "approvalPolicy": "never",
            "sandboxPolicy": ["type": "readOnly"]
        ])
        guard let turnID = (turn["turn"] as? [String: Any])?["id"] as? String else {
            throw PrimingError.invalidResponse("turn/start no devolvió un identificador")
        }
        let completed = try server.waitForNotification(method: "turn/completed", threadID: threadID,
                                                       turnID: turnID, timeout: 90)
        let status = (completed["turn"] as? [String: Any])?["status"] as? String
        guard status == "completed" else {
            throw PrimingError.invalidResponse("la interacción mínima terminó como \(status ?? "desconocido")")
        }
        Thread.sleep(forTimeInterval: 4)
        let after = try rateSnapshot(server)
        guard let reset = after.shortReset,
              reset.timeIntervalSince(started) > 17_400,
              reset.timeIntervalSince(started) < 18_600 else {
            throw PrimingError.invalidResponse("Codex no confirmó una ventana nueva de cinco horas")
        }
        ledger.accounts[profile.id.uuidString] = PrimingRecord(
            email: email, checkedAt: Date(), anchoredAt: started, resetAt: reset,
            model: model, effort: effort, status: "anchored", error: nil
        )
        saveLedger(&ledger)
    }

    private func validate(model: String, effort: String, server: PrimingAppServer) throws {
        let result = try server.request(method: "model/list", params: ["limit": 100])
        let models = result["data"] as? [[String: Any]] ?? []
        guard let selected = models.first(where: {
            (($0["model"] as? String) ?? ($0["id"] as? String)) == model && $0["hidden"] as? Bool != true
        }) else { throw PrimingError.invalidResponse("el modelo \(model) ya no está disponible") }
        let efforts = (selected["supportedReasoningEfforts"] as? [[String: Any]] ?? [])
            .compactMap { $0["reasoningEffort"] as? String }
        guard efforts.contains(effort) else {
            throw PrimingError.invalidResponse("\(model) no admite razonamiento \(effort)")
        }
    }

    private func rateSnapshot(_ server: PrimingAppServer) throws -> RateSnapshot {
        let result = try server.request(method: "account/rateLimits/read")
        let byID = result["rateLimitsByLimitId"] as? [String: Any]
        let snapshot = (byID?["codex"] as? [String: Any]) ?? (result["rateLimits"] as? [String: Any])
        guard let snapshot else {
            throw PrimingError.invalidResponse("no se recibieron ventanas de uso de Codex")
        }
        let windows = snapshot.values.compactMap { $0 as? [String: Any] }
        let hasDurations = windows.contains { number($0["windowDurationMins"]) != nil }
        let short = hasDurations
            ? windows.first { (number($0["windowDurationMins"])?.intValue ?? 1_440) < 1_440 }
            : snapshot["primary"] as? [String: Any]
        let weekly = hasDurations
            ? windows.first { (number($0["windowDurationMins"])?.intValue ?? 0) >= 1_440 }
            : snapshot["secondary"] as? [String: Any]
        let reason = snapshot["rateLimitReachedType"] as? String
        let spendBlocked = snapshot["spendControlReached"] as? Bool == true
        return RateSnapshot(
            shortUsed: number(short?["usedPercent"])?.intValue,
            shortReset: number(short?["resetsAt"]).map { Date(timeIntervalSince1970: $0.doubleValue) },
            weeklyUsed: number(weekly?["usedPercent"])?.intValue,
            blocked: reason != nil || spendBlocked
        )
    }

    private func isMovingCleanWindow(first: RateSnapshot, firstReadAt: Date,
                                     second: RateSnapshot, secondReadAt: Date) -> Bool {
        guard let firstReset = first.shortReset, let secondReset = second.shortReset else { return false }
        let elapsed = secondReadAt.timeIntervalSince(firstReadAt)
        let moved = secondReset.timeIntervalSince(firstReset)
        let firstIsFiveHours = abs(firstReset.timeIntervalSince(firstReadAt) - 18_000) < 20
        let secondIsFiveHours = abs(secondReset.timeIntervalSince(secondReadAt) - 18_000) < 20
        return firstIsFiveHours && secondIsFiveHours && abs(moved - elapsed) < 2
    }

    private func resolveAuth(email: String, profiles: [PulseProfile]) throws -> URL {
        var candidates = [sharedAuth]
        candidates.append(contentsOf: profiles.map {
            URL(fileURLWithPath: $0.codexHome, isDirectory: true).appendingPathComponent("auth.json")
        })
        if let found = candidates.first(where: {
            manager.fileExists(atPath: $0.path) && authEmail($0)?.caseInsensitiveCompare(email) == .orderedSame
        }) { return found }
        throw PrimingError.sessionMissing(email)
    }

    private func authEmail(_ file: URL) -> String? {
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String else { return nil }
        let parts = access.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var raw = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while raw.count % 4 != 0 { raw.append("=") }
        guard let payload = Data(base64Encoded: raw),
              let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        if let email = claims["email"] as? String { return email }
        return (claims["https://api.openai.com/profile"] as? [String: Any])?["email"] as? String
    }

    private func record(_ profile: PulseProfile, email: String, model: String, effort: String,
                        status: String, resetAt: Date?, ledger: inout PrimingLedger) {
        ledger.accounts[profile.id.uuidString] = PrimingRecord(
            email: email, checkedAt: Date(), anchoredAt: ledger.accounts[profile.id.uuidString]?.anchoredAt,
            resetAt: resetAt, model: model, effort: effort, status: status, error: nil
        )
        saveLedger(&ledger)
    }

    private func loadLedger() -> PrimingLedger {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: ledgerFile),
              let value = try? decoder.decode(PrimingLedger.self, from: data) else { return PrimingLedger() }
        return value
    }

    private func saveLedger(_ ledger: inout PrimingLedger) {
        ledger.updatedAt = Date()
        do {
            try manager.createDirectory(at: support, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(ledger).write(to: ledgerFile, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ledgerFile.path)
        } catch {}
    }

    private func number(_ value: Any?) -> NSNumber? {
        if let value = value as? NSNumber { return value }
        if let value = value as? String, let double = Double(value) { return NSNumber(value: double) }
        return nil
    }

    private func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

final class CodexLifecycleObserver {
    private var observer: NSObjectProtocol?

    func start() {
        installBridgeEnvironment()
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.openai.codex" else { return }
            self.openSwitchboardIfNeeded()
        }
        if !NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").isEmpty {
            openSwitchboardIfNeeded()
        }
    }

    private func installBridgeEnvironment() {
        let bridge = "/Applications/Codex Switchboard.app/Contents/Helpers/CodexHotBridge"
        guard FileManager.default.isExecutableFile(atPath: bridge) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["setenv", "CODEX_CLI_PATH", bridge]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    private func openSwitchboardIfNeeded() {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "local.codex.switchboard").isEmpty else { return }
        let appURL = URL(fileURLWithPath: "/Applications/Codex Switchboard.app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: appURL.path) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, _ in }
    }
}

let observer = CodexLifecycleObserver()
private let primer = WindowPrimingCoordinator()
observer.start()
primer.start()
RunLoop.main.run()
