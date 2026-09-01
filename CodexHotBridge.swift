import Foundation

private enum BridgeFailure: LocalizedError {
    case officialCodexMissing
    case invalidMessage(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .officialCodexMissing: return "No se encuentra el binario oficial de Codex."
        case .invalidMessage(let message): return message
        case .timedOut: return "Codex no respondió al cambio dentro del tiempo permitido."
        }
    }
}

private struct BridgeStatus: Codable {
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
    var rateLimits: BridgeRateLimits?
    var rateLimitsUpdatedAt: Date?
}

private struct BridgeUsageWindow: Codable {
    var usedPercent: Int
    var resetsAt: Date?
    var windowDurationMins: Int?
}

private struct BridgeRateLimits: Codable {
    var primary: BridgeUsageWindow?
    var secondary: BridgeUsageWindow?
    var rateLimitReachedType: String?
    var spendControlReached: Bool?
}

private struct ExternalAuth {
    var accessToken: String
    var accountID: String
    var plan: String?
}

private final class PendingRPC {
    private let condition = NSCondition()
    private var response: [String: Any]?

    func fulfill(_ value: [String: Any]) {
        condition.lock()
        response = value
        condition.broadcast()
        condition.unlock()
    }

    func wait(timeout: TimeInterval) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while response == nil {
            if !condition.wait(until: deadline) { throw BridgeFailure.timedOut }
        }
        return response ?? [:]
    }
}

private final class HotBridge {
    private let officialBinary: String
    private let child = Process()
    private let childInput = Pipe()
    private let childOutput = Pipe()
    private let childError = Pipe()
    private let childWriteLock = NSLock()
    private let stateLock = NSLock()
    private let pendingLock = NSLock()
    private var pendingRPC: [Int: PendingRPC] = [:]
    private var nextBridgeID = -1_000_000
    private var initialized = false
    private var initializeRequestID: String?
    private var desktopAuthStatusRequests: [String: Bool] = [:]
    private var currentAuthHome: String?
    private var currentExternalAuth: ExternalAuth?
    private var turnProfiles: [String: String] = [:]
    private var status: BridgeStatus

    private let fileManager = FileManager.default
    private let runtimeDirectory: URL
    private let commandsDirectory: URL
    private let statusFile: URL

    init(officialBinary: String) throws {
        self.officialBinary = officialBinary
        let defaultSupport = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Codex Switchboard", isDirectory: true)
        runtimeDirectory = ProcessInfo.processInfo.environment["CODEX_SWITCHBOARD_RUNTIME_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? defaultSupport.appendingPathComponent("Bridge", isDirectory: true)
        commandsDirectory = runtimeDirectory.appendingPathComponent("Commands", isDirectory: true)
        statusFile = runtimeDirectory.appendingPathComponent("status.json")
        status = BridgeStatus(
            pid: ProcessInfo.processInfo.processIdentifier,
            ready: false,
            version: "0.3.8",
            startedAt: Date(),
            updatedAt: Date(),
            activeThreadID: nil,
            activeTurnID: nil,
            activeItems: 0,
            pendingLimitThreadID: nil,
            pendingLimitTurnID: nil,
            pendingLimitAt: nil,
            pendingLimitProfileID: nil,
            activeProfileID: ProcessInfo.processInfo.environment["CODEX_SWITCHBOARD_ACTIVE_PROFILE_ID"],
            lastSwitchAt: nil,
            lastError: nil,
            rateLimits: nil,
            rateLimitsUpdatedAt: nil
        )
        try secureDirectory(runtimeDirectory)
        try secureDirectory(commandsDirectory)
    }

    func run(arguments: [String]) throws -> Never {
        guard fileManager.isExecutableFile(atPath: officialBinary) else {
            throw BridgeFailure.officialCodexMissing
        }
        child.executableURL = URL(fileURLWithPath: officialBinary)
        child.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_CLI_PATH"] = officialBinary
        environment.removeValue(forKey: "CODEX_SWITCHBOARD_ACTIVE_PROFILE_ID")
        child.environment = environment
        child.standardInput = childInput
        child.standardOutput = childOutput
        child.standardError = childError
        try child.run()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.pumpDesktopInput() }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.pumpChildOutput() }
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.pumpChildError() }
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.commandLoop() }

        child.waitUntilExit()
        updateStatus { value in
            value.ready = false
            if value.lastError == nil && self.child.terminationStatus != 0 {
                value.lastError = "El app-server oficial terminó con código \(self.child.terminationStatus)."
            }
        }
        Foundation.exit(child.terminationStatus)
    }

    private func pumpDesktopInput() {
        var buffer = Data()
        while true {
            let data = FileHandle.standardInput.availableData
            if data.isEmpty {
                try? childInput.fileHandleForWriting.close()
                return
            }
            buffer.append(data)
            consumeLines(from: &buffer) { [weak self] line in
                guard let self else { return }
                do {
                    let forwarded = try self.prepareDesktopMessage(line)
                    try self.writeToChild(forwarded)
                } catch {
                    self.recordError(error.localizedDescription)
                }
            }
        }
    }

    private func prepareDesktopMessage(_ line: Data) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return line
        }
        if object["method"] as? String == "initialize" {
            var params = object["params"] as? [String: Any] ?? [:]
            var capabilities = params["capabilities"] as? [String: Any] ?? [:]
            capabilities["experimentalApi"] = true
            params["capabilities"] = capabilities
            object["params"] = params
            stateLock.lock()
            initializeRequestID = rpcIDKey(object["id"])
            initialized = false
            stateLock.unlock()
        }
        if object["method"] as? String == "initialized" {
            stateLock.lock()
            initialized = true
            stateLock.unlock()
            updateStatus { $0.ready = true; $0.lastError = nil }
        }
        if object["method"] as? String == "getAuthStatus",
           let requestID = rpcIDKey(object["id"]) {
            let params = object["params"] as? [String: Any]
            stateLock.lock()
            desktopAuthStatusRequests[requestID] = params?["includeToken"] as? Bool ?? false
            stateLock.unlock()
        }
        var result = try JSONSerialization.data(withJSONObject: object)
        result.append(0x0A)
        return result
    }

    private func pumpChildOutput() {
        var buffer = Data()
        while true {
            let data = childOutput.fileHandleForReading.availableData
            if data.isEmpty { return }
            buffer.append(data)
            consumeLines(from: &buffer) { [weak self] line in self?.handleChildLine(line) }
        }
    }

    private func handleChildLine(_ line: Data) {
        guard var object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            writeToDesktop(line)
            return
        }
        completeInitializationIfNeeded(object)
        if let id = numericID(object["id"]), takePending(id: id, response: object) {
            return
        }
        if object["method"] as? String == "account/chatgptAuthTokens/refresh",
           let id = numericID(object["id"]) {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.answerExternalTokenRefresh(id: id)
            }
            return
        }
        rewriteDesktopAuthStatus(&object)
        rewriteExternalAuthNotification(&object)
        observe(object)
        if var forwarded = try? JSONSerialization.data(withJSONObject: object) {
            forwarded.append(0x0A)
            writeToDesktop(forwarded)
        } else {
            writeToDesktop(line)
        }
    }

    private func rewriteDesktopAuthStatus(_ object: inout [String: Any]) {
        guard let responseID = rpcIDKey(object["id"]) else { return }
        stateLock.lock()
        let includeToken = desktopAuthStatusRequests.removeValue(forKey: responseID)
        let auth = currentExternalAuth
        stateLock.unlock()
        guard let includeToken, let auth,
              object["error"] == nil,
              var result = object["result"] as? [String: Any] else { return }
        result["authMethod"] = "chatgpt"
        result["authToken"] = includeToken ? auth.accessToken : NSNull()
        result["requiresOpenaiAuth"] = true
        object["result"] = result
    }

    private func rewriteExternalAuthNotification(_ object: inout [String: Any]) {
        guard object["method"] as? String == "account/updated",
              var params = object["params"] as? [String: Any],
              params["authMode"] as? String == "chatgptAuthTokens" else { return }
        params["authMode"] = "chatgpt"
        object["params"] = params
    }

    private func completeInitializationIfNeeded(_ object: [String: Any]) {
        guard let responseID = rpcIDKey(object["id"]) else { return }
        stateLock.lock()
        guard initializeRequestID == responseID else {
            stateLock.unlock()
            return
        }
        initializeRequestID = nil
        let succeeded = object["error"] == nil
        initialized = succeeded
        stateLock.unlock()
        updateStatus {
            $0.ready = succeeded
            $0.lastError = succeeded ? nil : "Codex rechazó la inicialización del bridge."
        }
    }

    private func observe(_ object: [String: Any]) {
        guard let method = object["method"] as? String,
              let params = object["params"] as? [String: Any] else { return }
        switch method {
        case "turn/started":
            let turn = params["turn"] as? [String: Any]
            if let turnID = turn?["id"] as? String {
                stateLock.lock()
                if let profileID = status.activeProfileID { turnProfiles[turnID] = profileID }
                stateLock.unlock()
            }
            updateStatus {
                $0.activeThreadID = (params["threadId"] as? String) ?? $0.activeThreadID
                $0.activeTurnID = turn?["id"] as? String
                $0.activeItems = 0
            }
        case "item/started":
            updateStatus { $0.activeItems += 1 }
        case "item/completed":
            updateStatus { $0.activeItems = max(0, $0.activeItems - 1) }
        case "turn/completed":
            let turn = params["turn"] as? [String: Any]
            let error = turn?["error"] as? [String: Any]
            let info = error?["codexErrorInfo"] as? String
            let threadID = (params["threadId"] as? String) ?? statusSnapshot().activeThreadID
            let turnID = turn?["id"] as? String
            stateLock.lock()
            let turnProfileID = turnID.flatMap { turnProfiles.removeValue(forKey: $0) } ?? status.activeProfileID
            stateLock.unlock()
            updateStatus {
                $0.activeThreadID = nil
                $0.activeTurnID = nil
                $0.activeItems = 0
                if info == "usageLimitExceeded" {
                    $0.pendingLimitThreadID = threadID
                    $0.pendingLimitTurnID = turnID
                    $0.pendingLimitAt = Date()
                    $0.pendingLimitProfileID = turnProfileID
                }
            }
        case "account/rateLimits/updated":
            guard let snapshot = params["rateLimits"] as? [String: Any] else { return }
            let primary = bridgeWindow(snapshot["primary"])
            let secondary = bridgeWindow(snapshot["secondary"])
            updateStatus {
                $0.rateLimits = BridgeRateLimits(
                    primary: primary,
                    secondary: secondary,
                    rateLimitReachedType: snapshot["rateLimitReachedType"] as? String,
                    spendControlReached: snapshot["spendControlReached"] as? Bool
                )
                $0.rateLimitsUpdatedAt = Date()
            }
        default:
            break
        }
    }

    private func bridgeWindow(_ value: Any?) -> BridgeUsageWindow? {
        guard let object = value as? [String: Any],
              let used = (object["usedPercent"] as? NSNumber)?.intValue else { return nil }
        let reset = (object["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        return BridgeUsageWindow(
            usedPercent: used,
            resetsAt: reset,
            windowDurationMins: (object["windowDurationMins"] as? NSNumber)?.intValue
        )
    }

    private func pumpChildError() {
        while true {
            let data = childError.fileHandleForReading.availableData
            if data.isEmpty { return }
            try? FileHandle.standardError.write(contentsOf: data)
        }
    }

    private func commandLoop() {
        while child.isRunning {
            autoreleasepool { processCommands() }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private func processCommands() {
        guard let files = try? fileManager.contentsOfDirectory(
            at: commandsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for file in files where file.lastPathComponent.hasPrefix("request-") && file.pathExtension == "json" {
            let claimed = file.deletingPathExtension().appendingPathExtension("processing")
            do {
                try fileManager.moveItem(at: file, to: claimed)
                let request = try JSONSerialization.jsonObject(with: Data(contentsOf: claimed)) as? [String: Any] ?? [:]
                let response = handleCommand(request)
                try writeCommandResponse(response, requestFile: file)
            } catch {
                let response: [String: Any] = ["ok": false, "error": error.localizedDescription]
                try? writeCommandResponse(response, requestFile: file)
                recordError(error.localizedDescription)
            }
            try? fileManager.removeItem(at: claimed)
        }
    }

    private func handleCommand(_ request: [String: Any]) -> [String: Any] {
        guard let command = request["command"] as? String else {
            return ["ok": false, "error": "Orden de bridge no válida."]
        }
        do {
            switch command {
            case "ping":
                return ["ok": true, "ready": statusSnapshot().ready]
            case "switch":
                guard isInitialized() else { throw BridgeFailure.invalidMessage("Codex todavía está inicializando.") }
                guard let authPath = request["authPath"] as? String,
                      let profileID = request["profileID"] as? String else {
                    throw BridgeFailure.invalidMessage("Faltan los datos de la cuenta de destino.")
                }
                let auth = try loadAuth(path: authPath, refresh: false)
                let plan = request["plan"] as? String
                stateLock.lock()
                let previousHome = currentAuthHome
                let previousAuth = currentExternalAuth
                currentAuthHome = URL(fileURLWithPath: authPath).deletingLastPathComponent().path
                currentExternalAuth = ExternalAuth(
                    accessToken: auth.accessToken,
                    accountID: auth.accountID,
                    plan: plan
                )
                stateLock.unlock()
                do {
                    var login: [String: Any] = [
                        "type": "chatgptAuthTokens",
                        "accessToken": auth.accessToken,
                        "chatgptAccountId": auth.accountID
                    ]
                    if let plan { login["chatgptPlanType"] = plan }
                    _ = try rpc(method: "account/login/start", params: login, timeout: 10)
                } catch {
                    stateLock.lock()
                    currentAuthHome = previousHome
                    currentExternalAuth = previousAuth
                    stateLock.unlock()
                    throw error
                }
                updateStatus {
                    $0.activeProfileID = profileID
                    $0.lastSwitchAt = Date()
                    $0.lastError = nil
                }
                return ["ok": true]
            case "commit":
                if let authHome = request["authHome"] as? String {
                    stateLock.lock(); currentAuthHome = authHome; stateLock.unlock()
                }
                if let profileID = request["profileID"] as? String {
                    updateStatus { $0.activeProfileID = profileID }
                }
                return ["ok": true]
            case "continue":
                guard let threadID = request["threadID"] as? String else {
                    throw BridgeFailure.invalidMessage("No hay una conversación que continuar.")
                }
                let text = request["text"] as? String
                    ?? "Continúa exactamente desde el punto en que el límite de uso interrumpió la tarea. No repitas herramientas ni acciones ya completadas."
                _ = try rpc(method: "turn/start", params: [
                    "threadId": threadID,
                    "input": [["type": "text", "text": text]]
                ], timeout: 10)
                updateStatus {
                    $0.pendingLimitThreadID = nil
                    $0.pendingLimitTurnID = nil
                    $0.pendingLimitAt = nil
                    $0.pendingLimitProfileID = nil
                }
                return ["ok": true]
            case "ackLimit":
                updateStatus {
                    $0.pendingLimitThreadID = nil
                    $0.pendingLimitTurnID = nil
                    $0.pendingLimitAt = nil
                    $0.pendingLimitProfileID = nil
                }
                return ["ok": true]
            default:
                throw BridgeFailure.invalidMessage("Orden de bridge desconocida.")
            }
        } catch {
            return ["ok": false, "error": error.localizedDescription]
        }
    }

    private func writeCommandResponse(_ response: [String: Any], requestFile: URL) throws {
        let suffix = requestFile.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "request-", with: "")
        let destination = commandsDirectory.appendingPathComponent("response-\(suffix).json")
        let temporary = commandsDirectory.appendingPathComponent(".response-\(suffix).tmp")
        let data = try JSONSerialization.data(withJSONObject: response)
        try data.write(to: temporary, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.moveItem(at: temporary, to: destination)
    }

    private func rpc(method: String, params: [String: Any], timeout: TimeInterval) throws -> [String: Any] {
        let pending = PendingRPC()
        pendingLock.lock()
        let id = nextBridgeID
        nextBridgeID -= 1
        pendingRPC[id] = pending
        pendingLock.unlock()
        do {
            try writeJSONObjectToChild(["id": id, "method": method, "params": params])
            let response = try pending.wait(timeout: timeout)
            if let rpcError = response["error"] as? [String: Any] {
                throw BridgeFailure.invalidMessage(rpcError["message"] as? String ?? "Codex rechazó la operación.")
            }
            return response["result"] as? [String: Any] ?? [:]
        } catch {
            pendingLock.lock(); pendingRPC.removeValue(forKey: id); pendingLock.unlock()
            throw error
        }
    }

    private func takePending(id: Int, response: [String: Any]) -> Bool {
        pendingLock.lock()
        let pending = pendingRPC.removeValue(forKey: id)
        pendingLock.unlock()
        pending?.fulfill(response)
        return pending != nil
    }

    private func answerExternalTokenRefresh(id: Int) {
        do {
            stateLock.lock(); let home = currentAuthHome; stateLock.unlock()
            guard let home else { throw BridgeFailure.invalidMessage("No se conoce el almacén activo.") }
            let path = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("auth.json").path
            let auth = try loadAuth(path: path, refresh: true)
            stateLock.lock()
            let plan = currentExternalAuth?.plan
            currentExternalAuth = ExternalAuth(
                accessToken: auth.accessToken,
                accountID: auth.accountID,
                plan: plan
            )
            stateLock.unlock()
            var result: [String: Any] = [
                "accessToken": auth.accessToken,
                "chatgptAccountId": auth.accountID
            ]
            if let plan { result["chatgptPlanType"] = plan }
            try writeJSONObjectToChild(["id": id, "result": result])
        } catch {
            try? writeJSONObjectToChild([
                "id": id,
                "error": ["code": -32001, "message": "No se pudo renovar la autenticación externa."]
            ])
            recordError("No se pudo renovar la autenticación externa.")
        }
    }

    private func loadAuth(path: String, refresh: Bool) throws -> (accessToken: String, accountID: String) {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let allowedProfiles = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Codex Switchboard/Profiles", isDirectory: true)
            .standardizedFileURL.path + "/"
        let shared = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json").standardizedFileURL.path
        let testRoot = ProcessInfo.processInfo.environment["CODEX_SWITCHBOARD_TEST_AUTH_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path + "/" }
        guard url.path == shared || url.path.hasPrefix(allowedProfiles)
                || testRoot.map({ url.path.hasPrefix($0) }) == true else {
            throw BridgeFailure.invalidMessage("La ruta de autenticación no pertenece a Switchboard.")
        }
        if refresh {
            try refreshFileAuth(home: url.deletingLastPathComponent().path)
        }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let tokens = object?["tokens"] as? [String: Any]
        guard let accessToken = tokens?["access_token"] as? String, !accessToken.isEmpty,
              let accountID = tokens?["account_id"] as? String, !accountID.isEmpty else {
            throw BridgeFailure.invalidMessage("El perfil no contiene una sesión ChatGPT válida.")
        }
        return (accessToken, accountID)
    }

    private func refreshFileAuth(home: String) throws {
        let session = try MiniAppServer(binary: officialBinary, home: home)
        defer { session.stop() }
        try session.initialize()
        _ = try session.request(method: "account/read", params: ["refreshToken": true], timeout: 8)
    }

    private func writeJSONObjectToChild(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try writeToChild(data)
    }

    private func writeToChild(_ data: Data) throws {
        childWriteLock.lock(); defer { childWriteLock.unlock() }
        try childInput.fileHandleForWriting.write(contentsOf: data)
    }

    private func writeToDesktop(_ data: Data) {
        try? FileHandle.standardOutput.write(contentsOf: data)
    }

    private func isInitialized() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return initialized
    }

    private func updateStatus(_ change: (inout BridgeStatus) -> Void) {
        stateLock.lock()
        change(&status)
        status.updatedAt = Date()
        let snapshot = status
        stateLock.unlock()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        let temporary = runtimeDirectory.appendingPathComponent(".status-\(snapshot.pid).tmp")
        do {
            try data.write(to: temporary, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            if fileManager.fileExists(atPath: statusFile.path) { try fileManager.removeItem(at: statusFile) }
            try fileManager.moveItem(at: temporary, to: statusFile)
        } catch { try? fileManager.removeItem(at: temporary) }
    }

    private func statusSnapshot() -> BridgeStatus {
        stateLock.lock(); defer { stateLock.unlock() }
        return status
    }

    private func recordError(_ message: String) {
        updateStatus { $0.lastError = message }
    }

    private func secureDirectory(_ url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func consumeLines(from buffer: inout Data, handler: (Data) -> Void) {
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = Data(buffer.prefix(upTo: newline))
            buffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            line.append(0x0A)
            handler(line)
        }
    }

    private func numericID(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    private func rpcIDKey(_ value: Any?) -> String? {
        if let string = value as? String { return "string:\(string)" }
        if let number = value as? NSNumber { return "number:\(number.stringValue)" }
        return nil
    }
}

private final class MiniAppServer {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var nextID = 1

    init(binary: String, home: String) throws {
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["app-server", "--stdio"]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = home
        environment["CODEX_CLI_PATH"] = binary
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    func initialize() throws {
        _ = try request(method: "initialize", params: [
            "clientInfo": ["name": "codex-switchboard-bridge", "title": "Codex Switchboard Bridge", "version": "0.3.8"],
            "capabilities": ["experimentalApi": true]
        ], timeout: 5)
        try write(["method": "initialized"])
    }

    func request(method: String, params: [String: Any], timeout: TimeInterval) throws -> [String: Any] {
        let id = nextID; nextID += 1
        try write(["id": id, "method": method, "params": params])
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let message = try read()
            if let responseID = message["id"] as? Int, responseID == id {
                if let error = message["error"] as? [String: Any] {
                    throw BridgeFailure.invalidMessage(error["message"] as? String ?? "Falló la renovación de la cuenta.")
                }
                return message["result"] as? [String: Any] ?? [:]
            }
        }
        throw BridgeFailure.timedOut
    }

    func stop() { if process.isRunning { process.terminate() } }

    private func write(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object); data.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    private func read() throws -> [String: Any] {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.prefix(upTo: newline); buffer.removeSubrange(...newline)
                if let value = try JSONSerialization.jsonObject(with: line) as? [String: Any] { return value }
            }
            let data = output.fileHandleForReading.availableData
            if data.isEmpty { throw BridgeFailure.invalidMessage("El proceso de renovación terminó inesperadamente.") }
            buffer.append(data)
        }
    }
}

private func resolveOfficialBinary() -> String {
    if let override = ProcessInfo.processInfo.environment["CODEX_SWITCHBOARD_OFFICIAL_CLI"], !override.isEmpty {
        return override
    }
    return "/Applications/ChatGPT.app/Contents/Resources/codex"
}

private func isAuxiliaryCodexHost() -> Bool {
    if ProcessInfo.processInfo.environment["CODEX_SWITCHBOARD_FORCE_PASSTHROUGH"] == "1" { return true }
    // Tests use an explicit runtime and must exercise the bridge itself.
    if ProcessInfo.processInfo.environment["CODEX_SWITCHBOARD_RUNTIME_DIR"] != nil { return false }
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-o", "command=", "-p", String(getppid())]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        let command = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return command.contains("/cua_node/")
            || command.contains("node_repl")
            || command.contains("codex-code-mode-host")
    } catch {
        return false
    }
}

private func execOfficial(_ official: String, arguments: [String]) -> Never {
    guard FileManager.default.isExecutableFile(atPath: official) else { Foundation.exit(127) }
    var argv = [official] + arguments
    argv.withUnsafeMutableBufferPointer { buffer in
        let cStrings = buffer.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        var pointers = cStrings + [nil]
        _ = pointers.withUnsafeMutableBufferPointer { ptr in execv(official, ptr.baseAddress) }
    }
    Foundation.exit(127)
}

private let arguments = Array(CommandLine.arguments.dropFirst())
private let official = resolveOfficialBinary()
if arguments.contains("app-server") && !isAuxiliaryCodexHost() {
    do {
        let bridge = try HotBridge(officialBinary: official)
        try bridge.run(arguments: arguments)
    } catch {
        FileHandle.standardError.write(Data("Codex Switchboard Bridge: \(error.localizedDescription)\n".utf8))
        Foundation.exit(70)
    }
} else {
    execOfficial(official, arguments: arguments)
}
