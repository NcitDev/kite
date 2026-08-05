//
//  WorkspaceProfiles.swift
//  Telegram-Mac
//
//  Local workspace profiles and extensible agent integration.
//

import Cocoa
import Foundation
import InAppSettings
import Postbox
import SwiftSignalKit
import TelegramCore
import TGUIKit

enum WorkspaceProfileKind: String, Codable {
    case work
    case home
    case custom
}

struct WorkspaceProfile: Codable, Equatable {
    let id: String
    var name: String
    let kind: WorkspaceProfileKind
    var showsAllFolders: Bool
    var visibleFolderIds: [Int32]
    var receivesNotifications: Bool
    /// Namespaced switches allow later features to become profile-scoped without a migration.
    var featureFlags: [String: Bool]

    func displays(folderId: Int32) -> Bool {
        return showsAllFolders || visibleFolderIds.contains(folderId)
    }
}

struct WorkspaceACPConfiguration: Codable, Equatable {
    var executable: String
    var arguments: [String]
    var workingDirectory: String

    static var defaultValue: WorkspaceACPConfiguration {
        return WorkspaceACPConfiguration(
            executable: "/usr/bin/env",
            arguments: ["codex-acp"],
            workingDirectory: NSHomeDirectory()
        )
    }
}

struct WorkspaceProfileState: Codable, Equatable {
    var schemaVersion: Int
    var activeProfileId: String
    var profiles: [WorkspaceProfile]
    var acp: WorkspaceACPConfiguration

    static var defaultValue: WorkspaceProfileState {
        let work = WorkspaceProfile(
            id: "builtin.work",
            name: "Work",
            kind: .work,
            showsAllFolders: true,
            visibleFolderIds: [],
            receivesNotifications: true,
            featureFlags: [:]
        )
        let home = WorkspaceProfile(
            id: "builtin.home",
            name: "Home",
            kind: .home,
            showsAllFolders: true,
            visibleFolderIds: [],
            receivesNotifications: true,
            featureFlags: [:]
        )
        return WorkspaceProfileState(
            schemaVersion: 1,
            activeProfileId: work.id,
            profiles: [work, home],
            acp: .defaultValue
        )
    }

    var activeProfile: WorkspaceProfile {
        return profiles.first(where: { $0.id == activeProfileId }) ?? profiles.first ?? WorkspaceProfileState.defaultValue.profiles[0]
    }
}

final class WorkspaceProfileStore {
    private static let registryLock = NSLock()
    private static var registry: [Int64: WorkspaceProfileStore] = [:]

    static func shared(accountId: Int64) -> WorkspaceProfileStore {
        registryLock.lock()
        defer { registryLock.unlock() }
        if let current = registry[accountId] {
            return current
        }
        let current = WorkspaceProfileStore(accountId: accountId)
        registry[accountId] = current
        return current
    }

    private let storageKey: String
    private let value: Atomic<WorkspaceProfileState>
    private let promise: ValuePromise<WorkspaceProfileState>

    private init(accountId: Int64) {
        self.storageKey = "workspace-profiles.v1.\(accountId)"
        let decoded: WorkspaceProfileState
        if let data = UserDefaults.standard.data(forKey: self.storageKey),
           let state = try? JSONDecoder().decode(WorkspaceProfileState.self, from: data),
           !state.profiles.isEmpty {
            decoded = state
        } else {
            decoded = .defaultValue
        }
        self.value = Atomic(value: decoded)
        self.promise = ValuePromise(decoded, ignoreRepeated: true)
    }

    var signal: Signal<WorkspaceProfileState, NoError> {
        return promise.get()
    }

    var current: WorkspaceProfileState {
        return value.with { $0 }
    }

    private func update(_ transform: (inout WorkspaceProfileState) -> Void) {
        let updated = value.modify { current in
            var current = current
            transform(&current)
            if !current.profiles.contains(where: { $0.id == current.activeProfileId }) {
                current.activeProfileId = current.profiles[0].id
            }
            return current
        }
        if let data = try? JSONEncoder().encode(updated) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
        promise.set(updated)
    }

    func activate(_ profileId: String) {
        update { state in
            if state.profiles.contains(where: { $0.id == profileId }) {
                state.activeProfileId = profileId
            }
        }
    }

    func addCustomProfile() {
        update { state in
            let count = state.profiles.filter { $0.kind == .custom }.count + 1
            let profile = WorkspaceProfile(
                id: "custom.\(UUID().uuidString)",
                name: "Custom \(count)",
                kind: .custom,
                showsAllFolders: true,
                visibleFolderIds: [],
                receivesNotifications: true,
                featureFlags: [:]
            )
            state.profiles.append(profile)
            state.activeProfileId = profile.id
        }
    }

    func remove(_ profileId: String) {
        update { state in
            guard state.profiles.first(where: { $0.id == profileId })?.kind == .custom else {
                return
            }
            state.profiles.removeAll(where: { $0.id == profileId })
        }
    }

    func updateActive(_ transform: (inout WorkspaceProfile) -> Void) {
        update { state in
            guard let index = state.profiles.firstIndex(where: { $0.id == state.activeProfileId }) else {
                return
            }
            transform(&state.profiles[index])
        }
    }

    func updateACP(_ transform: (inout WorkspaceACPConfiguration) -> Void) {
        update { state in
            transform(&state.acp)
        }
    }

    func visibleFilters(_ filters: [ChatListFilter]) -> [ChatListFilter] {
        let profile = current.activeProfile
        let visible = filters.filter { profile.displays(folderId: $0.id) }
        if visible.isEmpty, let allChats = filters.first(where: { $0.isAllChats }) {
            return [allChats]
        }
        return visible
    }
}

enum WorkspaceACPStatus: Equatable {
    case disconnected
    case connecting
    case connected(agentName: String)
    case failed(String)

    var title: String {
        switch self {
        case .disconnected:
            return "Disconnected"
        case .connecting:
            return "Connecting…"
        case let .connected(agentName):
            return "Connected: \(agentName)"
        case let .failed(message):
            return "Failed: \(message)"
        }
    }
}

struct WorkspaceACPEvent {
    let sessionId: String
    let update: [String: Any]
}

/// Handles ACP extension requests without coupling the transport to Telegram features.
protocol WorkspaceACPRequestHandler: AnyObject {
    func handleACPRequest(method: String, params: [String: Any]?, completion: @escaping (Result<Any, Error>) -> Void) -> Bool
}

final class WorkspaceACPClient {
    private let queue = DispatchQueue(label: "telegram.workspace-acp")
    private let statusPromise = ValuePromise<WorkspaceACPStatus>(.disconnected, ignoreRepeated: true)
    private let eventPipe = ValuePipe<WorkspaceACPEvent>()
    private var process: Process?
    private var input: FileHandle?
    private var outputBuffer = Data()
    private var nextRequestId: Int = 1
    private var pending: [Int: ([String: Any]) -> Void] = [:]
    private var handlers: [WorkspaceACPRequestHandler] = []
    private var sessionId: String?

    var status: Signal<WorkspaceACPStatus, NoError> {
        return statusPromise.get()
    }

    /// Streams agent response chunks, plans, task/tool updates, and future ACP update types.
    var events: Signal<WorkspaceACPEvent, NoError> {
        return eventPipe.signal()
    }

    func register(_ handler: WorkspaceACPRequestHandler) {
        queue.async { [weak self, weak handler] in
            guard let self, let handler else { return }
            self.handlers.append(handler)
        }
    }

    func connect(configuration: WorkspaceACPConfiguration) {
        queue.async { [weak self] in
            self?.connectOnQueue(configuration: configuration)
        }
    }

    func disconnect() {
        queue.async { [weak self] in
            self?.stopOnQueue(status: .disconnected)
        }
    }

    func prompt(_ text: String, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        queue.async { [weak self] in
            guard let self, let sessionId = self.sessionId else {
                completion(.failure(WorkspaceACPClientError.notConnected))
                return
            }
            self.sendRequest(method: "session/prompt", params: [
                "sessionId": sessionId,
                "prompt": [["type": "text", "text": text]]
            ]) { response in
                if let error = response["error"] as? [String: Any] {
                    completion(.failure(WorkspaceACPClientError.remote(error["message"] as? String ?? "ACP prompt failed")))
                } else {
                    completion(.success(response["result"] as? [String: Any] ?? [:]))
                }
            }
        }
    }

    func cancelCurrentPrompt() {
        queue.async { [weak self] in
            guard let self, let sessionId = self.sessionId else { return }
            self.write(["jsonrpc": "2.0", "method": "session/cancel", "params": ["sessionId": sessionId]])
        }
    }

    private func connectOnQueue(configuration: WorkspaceACPConfiguration) {
        stopOnQueue(status: .connecting)
        statusPromise.set(.connecting)

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: configuration.executable)
        process.arguments = configuration.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: configuration.workingDirectory, isDirectory: true)
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.terminationHandler = { [weak self] task in
            self?.queue.async {
                guard let self, self.process === task else { return }
                self.stopOnQueue(status: .failed("Agent exited with status \(task.terminationStatus)"))
            }
        }

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async {
                self?.consume(data)
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            // ACP reserves stdout for protocol frames; drain diagnostic stderr without
            // treating ordinary agent logs as a connection failure.
            _ = handle.availableData
        }

        do {
            try process.run()
            self.process = process
            self.input = inputPipe.fileHandleForWriting
            sendRequest(method: "initialize", params: [
                "protocolVersion": 1,
                "clientCapabilities": [:],
                "clientInfo": [
                    "name": "telegram-mac",
                    "title": "Telegram for macOS",
                    "version": APP_VERSION_STRING
                ]
            ]) { [weak self] response in
                guard let self else { return }
                if let error = response["error"] as? [String: Any] {
                    self.stopOnQueue(status: .failed(error["message"] as? String ?? "ACP initialization failed"))
                    return
                }
                let result = response["result"] as? [String: Any]
                let info = result?["agentInfo"] as? [String: Any]
                let name = (info?["title"] as? String) ?? (info?["name"] as? String) ?? "Codex"
                self.sendRequest(method: "session/new", params: [
                    "cwd": configuration.workingDirectory,
                    "mcpServers": []
                ]) { [weak self] response in
                    guard let self else { return }
                    if let error = response["error"] as? [String: Any] {
                        self.stopOnQueue(status: .failed(error["message"] as? String ?? "ACP session creation failed"))
                        return
                    }
                    guard let result = response["result"] as? [String: Any], let sessionId = result["sessionId"] as? String else {
                        self.stopOnQueue(status: .failed("ACP agent returned no session ID"))
                        return
                    }
                    self.sessionId = sessionId
                    self.statusPromise.set(.connected(agentName: name))
                }
            }
        } catch {
            stopOnQueue(status: .failed(error.localizedDescription))
        }
    }

    private func stopOnQueue(status: WorkspaceACPStatus) {
        let current = process
        process = nil
        input = nil
        pending.removeAll()
        sessionId = nil
        outputBuffer.removeAll(keepingCapacity: false)
        current?.standardOutput.flatMap { ($0 as? Pipe)?.fileHandleForReading.readabilityHandler = nil }
        current?.standardError.flatMap { ($0 as? Pipe)?.fileHandleForReading.readabilityHandler = nil }
        if current?.isRunning == true {
            current?.terminate()
        }
        statusPromise.set(status)
    }

    private func sendRequest(method: String, params: [String: Any], completion: @escaping ([String: Any]) -> Void) {
        let id = nextRequestId
        nextRequestId += 1
        pending[id] = completion
        write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    }

    private func write(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object), var data = try? JSONSerialization.data(withJSONObject: object) else {
            return
        }
        data.append(0x0a)
        input?.write(data)
    }

    private func consume(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0a) {
            let line = outputBuffer.prefix(upTo: newline)
            outputBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                continue
            }
            receive(object)
        }
    }

    private func receive(_ object: [String: Any]) {
        if let id = object["id"] as? Int, object["method"] == nil {
            pending.removeValue(forKey: id)?(object)
            return
        }
        guard let method = object["method"] as? String else { return }
        let params = object["params"] as? [String: Any]
        if method == "session/update",
           let params,
           let sessionId = params["sessionId"] as? String,
           let update = params["update"] as? [String: Any] {
            eventPipe.putNext(WorkspaceACPEvent(sessionId: sessionId, update: update))
            return
        }
        guard let id = object["id"] as? Int else {
            return
        }
        for handler in handlers where handler.handleACPRequest(method: method, params: params, completion: { [weak self] result in
            self?.queue.async {
                switch result {
                case let .success(value):
                    self?.write(["jsonrpc": "2.0", "id": id, "result": value])
                case let .failure(error):
                    self?.write(["jsonrpc": "2.0", "id": id, "error": ["code": -32603, "message": error.localizedDescription]])
                }
            }
        }) {
            return
        }
        write(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not supported"]])
    }
}

private enum WorkspaceACPClientError: LocalizedError {
    case notConnected
    case remote(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Codex ACP is not connected"
        case let .remote(message):
            return message
        }
    }
}

final class WorkspaceACPRegistry {
    static let shared = WorkspaceACPRegistry()
    private let lock = NSLock()
    private var clients: [Int64: WorkspaceACPClient] = [:]

    func client(accountId: Int64) -> WorkspaceACPClient {
        lock.lock()
        defer { lock.unlock() }
        if let current = clients[accountId] {
            return current
        }
        let current = WorkspaceACPClient()
        clients[accountId] = current
        return current
    }
}

enum WorkspaceMessageScheduler {
    /// Telegram stores the schedule on the outgoing message, so delivery survives app restarts.
    static func schedule(context: AccountContext, peerId: PeerId, text: String, at date: Date) -> Signal<[MessageId?], NoError> {
        let timestamp = max(Int32(Date().timeIntervalSince1970 + 1), Int32(date.timeIntervalSince1970))
        let attributes: [MessageAttribute] = [OutgoingScheduleInfoMessageAttribute(scheduleTime: timestamp)]
        let message = EnqueueMessage.message(
            text: text,
            attributes: attributes,
            inlineStickers: [:],
            mediaReference: nil,
            threadId: nil,
            replyToMessageId: nil,
            replyToStoryId: nil,
            localGroupingKey: nil,
            correlationId: nil,
            bubbleUpEmojiOrStickersets: []
        )
        return enqueueMessages(account: context.account, peerId: peerId, messages: [message])
    }
}

private let workspaceProfileNameId = InputDataIdentifier("workspace.profile.name")
private let workspaceACPExecutableId = InputDataIdentifier("workspace.acp.executable")
private let workspaceACPDirectoryId = InputDataIdentifier("workspace.acp.directory")

private func workspaceProfileEntries(
    state: WorkspaceProfileState,
    filters: [ChatListFilter],
    acpStatus: WorkspaceACPStatus,
    store: WorkspaceProfileStore,
    client: WorkspaceACPClient
) -> [InputDataEntry] {
    var entries: [InputDataEntry] = []
    var sectionId: Int32 = 0
    var index: Int32 = 0

    entries.append(.sectionId(sectionId, type: .normal))
    sectionId += 1
    entries.append(.desc(sectionId: sectionId, index: index, text: .plain("PROFILES"), data: .init(color: theme.colors.listGrayText, detectBold: true, viewType: .textTopItem)))
    index += 1
    for profile in state.profiles {
        entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: InputDataIdentifier("workspace.profile.\(profile.id)"), data: .init(
            name: profile.name,
            color: theme.colors.text,
            type: .selectable(profile.id == state.activeProfileId),
            viewType: bestGeneralViewType(state.profiles, for: profile),
            action: { store.activate(profile.id) },
            menuItems: profile.kind == .custom ? {
                return [ContextMenuItem("Delete Profile", handler: { store.remove(profile.id) }, itemMode: .destruct)]
            } : nil
        )))
        index += 1
    }
    entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: InputDataIdentifier("workspace.profile.add"), data: .init(name: "Add Custom Profile", color: theme.colors.accent, type: .none, viewType: .singleItem, action: store.addCustomProfile)))
    index += 1

    entries.append(.sectionId(sectionId, type: .normal))
    sectionId += 1
    let active = state.activeProfile
    if active.kind == .custom {
        entries.append(.input(sectionId: sectionId, index: index, value: .string(active.name), error: nil, identifier: workspaceProfileNameId, mode: .plain, data: .init(viewType: .singleItem), placeholder: nil, inputPlaceholder: "Profile name", filter: { $0 }, limit: 64))
        index += 1
    }
    entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: InputDataIdentifier("workspace.notifications"), data: .init(name: "Receive Notifications", color: theme.colors.text, type: .switchable(active.receivesNotifications), viewType: .singleItem, action: {
        store.updateActive { $0.receivesNotifications.toggle() }
    }, autoswitch: false)))
    index += 1
    entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: InputDataIdentifier("workspace.folders.all"), data: .init(name: "Show All Chat Folders", color: theme.colors.text, type: .switchable(active.showsAllFolders), viewType: .singleItem, action: {
        store.updateActive { $0.showsAllFolders.toggle() }
    }, autoswitch: false)))
    index += 1
    if !active.showsAllFolders {
        entries.append(.desc(sectionId: sectionId, index: index, text: .plain("VISIBLE CHAT FOLDERS"), data: .init(color: theme.colors.listGrayText, detectBold: true, viewType: .textTopItem)))
        index += 1
        for filter in filters {
            entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: InputDataIdentifier("workspace.folder.\(filter.id)"), data: .init(name: filter.title, color: theme.colors.text, type: .switchable(active.visibleFolderIds.contains(filter.id)), viewType: bestGeneralViewType(filters, for: filter), action: {
                store.updateActive { profile in
                    if let position = profile.visibleFolderIds.firstIndex(of: filter.id) {
                        profile.visibleFolderIds.remove(at: position)
                    } else {
                        profile.visibleFolderIds.append(filter.id)
                    }
                }
            }, autoswitch: false)))
            index += 1
        }
    }

    entries.append(.sectionId(sectionId, type: .normal))
    sectionId += 1
    entries.append(.desc(sectionId: sectionId, index: index, text: .plain("CODEX ACP"), data: .init(color: theme.colors.listGrayText, detectBold: true, viewType: .textTopItem)))
    index += 1
    entries.append(.input(sectionId: sectionId, index: index, value: .string(state.acp.executable), error: nil, identifier: workspaceACPExecutableId, mode: .plain, data: .init(viewType: .firstItem), placeholder: nil, inputPlaceholder: "ACP executable", filter: { $0 }, limit: 1024))
    index += 1
    entries.append(.input(sectionId: sectionId, index: index, value: .string(state.acp.workingDirectory), error: nil, identifier: workspaceACPDirectoryId, mode: .plain, data: .init(viewType: .lastItem), placeholder: nil, inputPlaceholder: "Working directory", filter: { $0 }, limit: 2048))
    index += 1
    let isConnected: Bool
    switch acpStatus {
    case .connected, .connecting:
        isConnected = true
    default:
        isConnected = false
    }
    entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: InputDataIdentifier("workspace.acp.connect"), data: .init(name: isConnected ? "Disconnect Codex" : "Connect to Codex", color: theme.colors.accent, type: .nextContext(acpStatus.title), viewType: .singleItem, action: {
        if isConnected {
            client.disconnect()
        } else {
            client.connect(configuration: store.current.acp)
        }
    })))
    index += 1
    entries.append(.desc(sectionId: sectionId, index: index, text: .plain("Uses ACP v1 over stdio. The default launches the codex-acp adapter. New Telegram chat, response, and task capabilities can be added through WorkspaceACPRequestHandler."), data: .init(color: theme.colors.listGrayText, viewType: .textBottomItem)))
    index += 1

    entries.append(.sectionId(sectionId, type: .normal))
    sectionId += 1
    entries.append(.desc(sectionId: sectionId, index: index, text: .plain("TIMED MESSAGES"), data: .init(color: theme.colors.listGrayText, detectBold: true, viewType: .textTopItem)))
    index += 1
    entries.append(.desc(sectionId: sectionId, index: index, text: .plain("Use Send Later in any chat. Timed messages are stored by Telegram and fire even when this app is closed; integrations can call WorkspaceMessageScheduler for the same behavior."), data: .init(color: theme.colors.listGrayText, viewType: .textBottomItem)))
    index += 1
    return entries
}

func WorkspaceProfilesController(context: AccountContext) -> InputDataController {
    let accountId = context.account.id.int64
    let store = WorkspaceProfileStore.shared(accountId: accountId)
    let client = WorkspaceACPRegistry.shared.client(accountId: accountId)
    let filters = chatListFilterPreferences(engine: context.engine) |> map { $0.list }
    let signal = combineLatest(queue: prepareQueue, appearanceSignal, store.signal, filters, client.status)
    |> map { _, state, filters, acpStatus in
        return InputDataSignalValue(entries: workspaceProfileEntries(state: state, filters: filters, acpStatus: acpStatus, store: store, client: client))
    }
    let controller = InputDataController(dataSignal: signal, title: "Profiles & Automation", removeAfterDisappear: false, hasDone: false, identifier: "workspace_profiles")
    controller.updateDatas = { data in
        if let name = data[workspaceProfileNameId]?.stringValue, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            store.updateActive { profile in
                if profile.kind == .custom {
                    profile.name = name
                }
            }
        }
        store.updateACP { configuration in
            if let executable = data[workspaceACPExecutableId]?.stringValue, !executable.isEmpty {
                configuration.executable = executable
            }
            if let directory = data[workspaceACPDirectoryId]?.stringValue, !directory.isEmpty {
                configuration.workingDirectory = directory
            }
        }
        return .none
    }
    controller.validateData = { _ in .none }
    return controller
}
