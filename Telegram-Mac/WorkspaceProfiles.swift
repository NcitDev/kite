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

enum WorkspaceKnowledgeIntegrationKind: String, Codable {
    case obsidian

    var title: String {
        switch self {
        case .obsidian:
            return "Obsidian Vault"
        }
    }
}

struct WorkspaceKnowledgeIntegration: Codable, Equatable {
    let id: String
    var name: String
    let kind: WorkspaceKnowledgeIntegrationKind
    var rootPath: String
    var instructions: String
    var isEnabled: Bool
    var usesLocalSearch: Bool
    var exposesCodexTools: Bool

    static func obsidian() -> WorkspaceKnowledgeIntegration {
        return WorkspaceKnowledgeIntegration(
            id: "obsidian.\(UUID().uuidString)",
            name: "Obsidian",
            kind: .obsidian,
            rootPath: "",
            instructions: "Use these notes as my personal knowledge base. Prefer relevant notes over guesses and cite the relative note path when you use them.",
            isEnabled: true,
            usesLocalSearch: true,
            exposesCodexTools: true
        )
    }

    var expandedRootPath: String {
        return (rootPath as NSString).expandingTildeInPath
    }

    var hasValidRoot: Bool {
        var isDirectory: ObjCBool = false
        return !expandedRootPath.isEmpty
            && FileManager.default.fileExists(atPath: expandedRootPath, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}

struct WorkspaceProfile: Codable, Equatable {
    let id: String
    var name: String
    let kind: WorkspaceProfileKind
    var showsAllFolders: Bool
    var visibleFolderIds: [Int32]
    var receivesNotifications: Bool
    var showsStories: Bool
    var includedPeerIds: [Int64]
    /// Namespaced switches allow later features to become profile-scoped without a migration.
    var featureFlags: [String: Bool]
    /// Knowledge integrations are profile-scoped so Work and Home never share sources implicitly.
    var knowledgeIntegrations: [WorkspaceKnowledgeIntegration]
    /// How far back the in-chat panel looks once "Today" is cleared.
    var chatRangePreset: WorkspaceChatRangePreset
    /// Optional on-device speech-to-text server, used instead of Telegram's Premium transcription.
    var localTranscription: WorkspaceLocalTranscription

    func displays(folderId: Int32) -> Bool {
        return showsAllFolders || visibleFolderIds.contains(folderId)
    }

    /// The single switch that decides whether an action appears in the in-chat panel.
    func isEnabled(_ action: CodexAssistantAction) -> Bool {
        return featureFlags[action.flagKey] ?? action.isEnabledByDefault
    }

    /// Capabilities announced to the agent are derived from the actions actually switched on,
    /// so there is no second set of switches to keep in sync.
    var advertisedFeatures: [WorkspaceAIFeature] {
        return WorkspaceAIFeature.allCases.filter { feature in
            CodexAssistantAction.configurable.contains { $0.feature == feature && isEnabled($0) }
        }
    }
}

extension WorkspaceProfile {
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case kind
        case showsAllFolders
        case visibleFolderIds
        case receivesNotifications
        case showsStories
        case includedPeerIds
        case featureFlags
        case knowledgeIntegrations
        case chatRangePreset
        case localTranscription
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.kind = try container.decode(WorkspaceProfileKind.self, forKey: .kind)
        self.showsAllFolders = try container.decodeIfPresent(Bool.self, forKey: .showsAllFolders) ?? true
        self.visibleFolderIds = try container.decodeIfPresent([Int32].self, forKey: .visibleFolderIds) ?? []
        self.receivesNotifications = try container.decodeIfPresent(Bool.self, forKey: .receivesNotifications) ?? true
        self.showsStories = try container.decodeIfPresent(Bool.self, forKey: .showsStories) ?? true
        self.includedPeerIds = try container.decodeIfPresent([Int64].self, forKey: .includedPeerIds) ?? []
        self.featureFlags = try container.decodeIfPresent([String: Bool].self, forKey: .featureFlags) ?? [:]
        self.knowledgeIntegrations = try container.decodeIfPresent([WorkspaceKnowledgeIntegration].self, forKey: .knowledgeIntegrations) ?? []
        self.chatRangePreset = try container.decodeIfPresent(WorkspaceChatRangePreset.self, forKey: .chatRangePreset) ?? .sevenDays
        self.localTranscription = try container.decodeIfPresent(WorkspaceLocalTranscription.self, forKey: .localTranscription) ?? .defaultValue
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(kind, forKey: .kind)
        try container.encode(showsAllFolders, forKey: .showsAllFolders)
        try container.encode(visibleFolderIds, forKey: .visibleFolderIds)
        try container.encode(receivesNotifications, forKey: .receivesNotifications)
        try container.encode(showsStories, forKey: .showsStories)
        try container.encode(includedPeerIds, forKey: .includedPeerIds)
        try container.encode(featureFlags, forKey: .featureFlags)
        try container.encode(knowledgeIntegrations, forKey: .knowledgeIntegrations)
        try container.encode(chatRangePreset, forKey: .chatRangePreset)
        try container.encode(localTranscription, forKey: .localTranscription)
    }
}

enum WorkspaceACPProvider: String, Codable, CaseIterable {
    case codex
    case claude
    case opencode
    case custom

    var title: String {
        switch self {
        case .codex:
            return "Codex"
        case .claude:
            return "Claude"
        case .opencode:
            return "opencode"
        case .custom:
            return "Custom ACP Agent"
        }
    }

    var defaultArguments: [String] {
        switch self {
        case .codex:
            return ["npx", "-y", "@agentclientprotocol/codex-acp"]
        case .claude:
            return ["npx", "-y", "@agentclientprotocol/claude-agent-acp"]
        case .opencode:
            /// opencode ships its own binary and exposes ACP as a subcommand.
            return ["opencode", "acp"]
        case .custom:
            return []
        }
    }

    /// Fallback offered before the agent has ever reported its own list. Only filled in where
    /// the identifiers are known for certain — everything else comes from the connected agent.
    var suggestedModels: [String] {
        switch self {
        case .claude:
            return ["claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5", "claude-opus-4-8"]
        case .codex, .opencode, .custom:
            return []
        }
    }

    /// Empty means "let the agent choose", which is the only safe default for an agent whose
    /// model identifiers we do not know.
    var defaultModel: String {
        return ""
    }
}

/// A model the connected agent reported it can run.
struct WorkspaceACPModel: Equatable {
    let id: String
    let name: String
}

struct WorkspaceACPConfiguration: Codable, Equatable {
    var provider: WorkspaceACPProvider
    var executable: String
    var arguments: [String]
    var workingDirectory: String
    var autoConnect: Bool
    /// Empty means "let the agent pick"; otherwise appended to the launch arguments.
    var model: String

    static var defaultValue: WorkspaceACPConfiguration {
        return WorkspaceACPConfiguration(
            provider: .codex,
            executable: "/usr/bin/env",
            arguments: WorkspaceACPProvider.codex.defaultArguments,
            workingDirectory: NSHomeDirectory(),
            autoConnect: true,
            model: WorkspaceACPProvider.codex.defaultModel
        )
    }

    /// The launch arguments with the model flag applied. Kept out of `arguments` itself so the
    /// picker can change the model without rewriting what the user typed.
    var launchArguments: [String] {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !arguments.contains("--model") else {
            return arguments
        }
        return arguments + ["--model", trimmed]
    }

    mutating func selectProvider(_ provider: WorkspaceACPProvider) {
        self.provider = provider
        guard provider != .custom else {
            return
        }
        self.executable = "/usr/bin/env"
        self.arguments = provider.defaultArguments
        /// A model id from another provider is meaningless here.
        if !provider.suggestedModels.contains(model) {
            self.model = provider.defaultModel
        }
    }

    private enum CodingKeys: String, CodingKey {
        case provider
        case executable
        case arguments
        case workingDirectory
        case autoConnect
        case model
    }

    init(provider: WorkspaceACPProvider, executable: String, arguments: [String], workingDirectory: String, autoConnect: Bool, model: String) {
        self.provider = provider
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.autoConnect = autoConnect
        self.model = model
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let executable = try container.decode(String.self, forKey: .executable)
        var arguments = try container.decode([String].self, forKey: .arguments)
        let inferredProvider: WorkspaceACPProvider
        if arguments.contains(where: { $0.contains("claude") }) {
            inferredProvider = .claude
        } else if arguments.contains(where: { $0.contains("codex") }) {
            inferredProvider = .codex
        } else if arguments.contains(where: { $0.contains("opencode") }) {
            inferredProvider = .opencode
        } else {
            inferredProvider = .custom
        }
        let provider = try container.decodeIfPresent(WorkspaceACPProvider.self, forKey: .provider) ?? inferredProvider
        if executable == "/usr/bin/env", arguments == ["codex-acp"] {
            arguments = WorkspaceACPProvider.codex.defaultArguments
        }
        self.init(
            provider: provider,
            executable: executable,
            arguments: arguments,
            workingDirectory: try container.decode(String.self, forKey: .workingDirectory),
            autoConnect: try container.decodeIfPresent(Bool.self, forKey: .autoConnect) ?? true,
            model: try container.decodeIfPresent(String.self, forKey: .model) ?? provider.defaultModel
        )
    }
}

/// Coarse capability announced to the agent on connect. Derived from the enabled chat actions;
/// there is no separate user-facing switch.
enum WorkspaceAIFeature: String, CaseIterable {
    case chatSummaries = "ai.chat-summaries"
    case replyDrafts = "ai.reply-drafts"

    var title: String {
        switch self {
        case .chatSummaries:
            return "Chat Summaries"
        case .replyDrafts:
            return "Reply Drafts"
        }
    }

    var isWriteCapability: Bool {
        return self == .replyDrafts
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
            showsStories: true,
            includedPeerIds: [],
            featureFlags: [:],
            knowledgeIntegrations: [],
            chatRangePreset: .sevenDays,
            localTranscription: .defaultValue
        )
        let home = WorkspaceProfile(
            id: "builtin.home",
            name: "Home",
            kind: .home,
            showsAllFolders: true,
            visibleFolderIds: [],
            receivesNotifications: true,
            showsStories: true,
            includedPeerIds: [],
            featureFlags: [:],
            knowledgeIntegrations: [],
            chatRangePreset: .sevenDays,
            localTranscription: .defaultValue
        )
        return WorkspaceProfileState(
            schemaVersion: 3,
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
    static let profileChatsFilterId = Int32.min
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
           var state = try? JSONDecoder().decode(WorkspaceProfileState.self, from: data),
           !state.profiles.isEmpty {
            state.schemaVersion = max(state.schemaVersion, 3)
            decoded = state
        } else {
            decoded = .defaultValue
        }
        self.value = Atomic(value: decoded)
        // Badge-only updates intentionally re-emit the same persisted profile state so
        // synthetic folder titles can refresh without changing profile configuration.
        self.promise = ValuePromise(decoded, ignoreRepeated: false)
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
                showsStories: true,
                includedPeerIds: [],
                featureFlags: [:],
                knowledgeIntegrations: [],
                chatRangePreset: .sevenDays,
            localTranscription: .defaultValue
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

    func addObsidianIntegration() {
        updateActive { profile in
            profile.knowledgeIntegrations.append(.obsidian())
        }
    }

    func removeIntegration(_ integrationId: String) {
        updateActive { profile in
            profile.knowledgeIntegrations.removeAll(where: { $0.id == integrationId })
        }
    }

    func profileChatsFilter(for profile: WorkspaceProfile? = nil) -> ChatListFilter? {
        let profile = profile ?? current.activeProfile
        let peerIds = profile.includedPeerIds.map(PeerId.init)
        guard !peerIds.isEmpty else {
            return nil
        }
        var includePeers = ChatListFilterIncludePeers()
        includePeers.setPeers(peerIds)
        let data = ChatListFilterData(
            isShared: false,
            hasSharedLinks: false,
            categories: [],
            excludeMuted: false,
            excludeRead: false,
            excludeArchived: false,
            includePeers: includePeers,
            excludePeers: [],
            color: nil
        )
        return .filter(
            id: WorkspaceProfileStore.profileChatsFilterId,
            title: ChatFolderTitle(text: "\(profile.name) Chats", entities: [], enableAnimations: true),
            emoticon: "💬",
            data: data
        )
    }

    private func includingProfileChats(_ filter: ChatListFilter, profile: WorkspaceProfile) -> ChatListFilter {
        guard case let .filter(id, title, emoticon, sourceData) = filter else {
            return filter
        }
        var data = sourceData
        for peerId in profile.includedPeerIds.map(PeerId.init) {
            _ = data.addIncludePeer(peerId: peerId)
        }
        return .filter(id: id, title: title, emoticon: emoticon, data: data)
    }

    func visibleFilters(_ filters: [ChatListFilter]) -> [ChatListFilter] {
        let profile = current.activeProfile
        let profileFilter = profileChatsFilter(for: profile)
        var visible = filters.filter { profile.displays(folderId: $0.id) }.map {
            includingProfileChats($0, profile: profile)
        }
        if visible.isEmpty, profileFilter == nil, let allChats = filters.first(where: { $0.isAllChats }) {
            visible = [allChats]
        }
        if let profileFilter {
            visible.insert(profileFilter, at: 0)
        }
        return visible
    }
}

struct WorkspaceKnowledgeSnippet {
    let integrationName: String
    let relativePath: String
    let text: String
    let instructions: String
    let score: Int
}

final class WorkspaceKnowledgeRetriever {
    static let shared = WorkspaceKnowledgeRetriever()

    private let queue = DispatchQueue(label: "telegram.workspace-knowledge", qos: .userInitiated)
    private let stopWords: Set<String> = [
        "about", "after", "again", "also", "and", "are", "been", "before", "but", "can", "could",
        "does", "for", "from", "have", "help", "into", "just", "more", "not", "only", "our", "please",
        "should", "that", "the", "their", "them", "then", "there", "these", "they", "this", "those",
        "want", "was", "what", "when", "where", "which", "with", "would", "you", "your"
    ]

    func search(
        query: String,
        integrations: [WorkspaceKnowledgeIntegration],
        completion: @escaping ([WorkspaceKnowledgeSnippet]) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            let results = self.searchOnQueue(query: query, integrations: integrations)
            DispatchQueue.main.async {
                completion(results)
            }
        }
    }

    private func searchOnQueue(query: String, integrations: [WorkspaceKnowledgeIntegration]) -> [WorkspaceKnowledgeSnippet] {
        let tokens = query
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !stopWords.contains($0) }
            .reduce(into: [String]()) { result, token in
                if !result.contains(token), result.count < 20 {
                    result.append(token)
                }
            }
        guard !tokens.isEmpty else {
            return []
        }

        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var results: [WorkspaceKnowledgeSnippet] = []
        for integration in integrations where integration.isEnabled && integration.usesLocalSearch && integration.hasValidRoot {
            let rootURL = URL(fileURLWithPath: integration.expandedRootPath, isDirectory: true).standardizedFileURL
            let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
            guard let enumerator = FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else {
                continue
            }

            var scannedFiles = 0
            while let fileURL = enumerator.nextObject() as? URL, scannedFiles < 5000 {
                guard let values = try? fileURL.resourceValues(forKeys: Set(keys)) else {
                    continue
                }
                if values.isSymbolicLink == true {
                    if values.isDirectory == true {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                if values.isDirectory == true {
                    if fileURL.lastPathComponent == ".obsidian" {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                guard values.isRegularFile == true,
                      fileURL.pathExtension.lowercased() == "md",
                      (values.fileSize ?? 0) <= 1_048_576 else {
                    continue
                }
                scannedFiles += 1
                guard let content = try? String(contentsOf: fileURL, encoding: .utf8), !content.isEmpty else {
                    continue
                }

                let relativePath = String(fileURL.path.dropFirst(min(rootURL.path.count + 1, fileURL.path.count)))
                let searchablePath = relativePath.lowercased()
                let searchableContent = content.lowercased()
                var score = 0
                var firstMatch: String.Index?
                for token in tokens {
                    if searchablePath.contains(token) {
                        score += 6
                    }
                    if let range = content.range(of: token, options: [.caseInsensitive, .diacriticInsensitive]) {
                        score += 2
                        if firstMatch == nil || range.lowerBound < firstMatch! {
                            firstMatch = range.lowerBound
                        }
                    }
                }
                if normalizedQuery.count > 4, searchableContent.contains(normalizedQuery) {
                    score += 12
                }
                guard score > 0 else {
                    continue
                }

                let excerpt: String
                if let firstMatch {
                    let start = content.index(firstMatch, offsetBy: -500, limitedBy: content.startIndex) ?? content.startIndex
                    let end = content.index(firstMatch, offsetBy: 1100, limitedBy: content.endIndex) ?? content.endIndex
                    excerpt = String(content[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    excerpt = String(content.prefix(1400)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                results.append(WorkspaceKnowledgeSnippet(
                    integrationName: integration.name,
                    relativePath: relativePath,
                    text: excerpt,
                    instructions: integration.instructions,
                    score: score
                ))
            }
        }
        return Array(results.sorted { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            return lhs.relativePath < rhs.relativePath
        }.prefix(8))
    }
}

enum WorkspaceACPStatus: Equatable {
    case disconnected
    case connecting
    case connected(agentName: String)
    case authenticationRequired(agentName: String, methods: [WorkspaceACPAuthMethod])
    case failed(String)

    var title: String {
        switch self {
        case .disconnected:
            return "Disconnected"
        case .connecting:
            return "Connecting…"
        case let .connected(agentName):
            return "Connected: \(agentName)"
        case let .authenticationRequired(agentName, _):
            return "Sign in to \(agentName)"
        case let .failed(message):
            return "Failed: \(message)"
        }
    }
}

struct WorkspaceACPAuthMethod: Equatable {
    let id: String
    let name: String
    let description: String?
}

struct WorkspaceACPPermissionOption {
    let id: String
    let name: String
    let kind: String
}

typealias WorkspaceACPPermissionHandler = (
    _ title: String,
    _ options: [WorkspaceACPPermissionOption],
    _ completion: @escaping (String?) -> Void
) -> Void

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
    private let modelsPromise = ValuePromise<[WorkspaceACPModel]>([], ignoreRepeated: true)
    private let currentModelPromise = ValuePromise<String>("", ignoreRepeated: true)
    private var modelUsesConfigOption = false
    private let eventPipe = ValuePipe<WorkspaceACPEvent>()
    private var process: Process?
    private var input: FileHandle?
    private var outputBuffer = Data()
    private var nextRequestId: Int = 1
    private var pending: [Int: ([String: Any]) -> Void] = [:]
    private var handlers: [WorkspaceACPRequestHandler] = []
    private var sessionId: String?
    private var configuration: WorkspaceACPConfiguration?
    private var agentName: String?
    private var authenticationMethods: [WorkspaceACPAuthMethod] = []
    private var permissionHandler: WorkspaceACPPermissionHandler?
    private var knowledgeIntegrations: [WorkspaceKnowledgeIntegration] = []

    var status: Signal<WorkspaceACPStatus, NoError> {
        return statusPromise.get()
    }

    /// Models the agent advertised on its last successful session. Empty when the agent does
    /// not report any, in which case the picker falls back to the provider's known list.
    var models: Signal<[WorkspaceACPModel], NoError> {
        return modelsPromise.get()
    }

    /// Model the agent says the live session is using.
    var currentModel: Signal<String, NoError> {
        return currentModelPromise.get()
    }

    /// Switches model on the running session. ACP exposes `session/set_model`, so there is no
    /// need to tear the agent process down just to change model.
    func selectModel(_ modelId: String) {
        queue.async { [weak self] in
            guard let self, let sessionId = self.sessionId else { return }
            let method = self.modelUsesConfigOption ? "session/set_config_option" : "session/set_model"
            let params: [String: Any] = self.modelUsesConfigOption
                ? ["sessionId": sessionId, "configId": "model", "value": modelId]
                : ["sessionId": sessionId, "modelId": modelId]
            self.sendRequest(method: method, params: params) { [weak self] response in
                guard let self else { return }
                if response["error"] == nil {
                    self.currentModelPromise.set(modelId)
                }
            }
        }
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

    func connect(
        configuration: WorkspaceACPConfiguration,
        enabledFeatures: [WorkspaceAIFeature],
        knowledgeIntegrations: [WorkspaceKnowledgeIntegration],
        permissionHandler: @escaping WorkspaceACPPermissionHandler
    ) {
        queue.async { [weak self] in
            self?.connectOnQueue(
                configuration: configuration,
                enabledFeatures: enabledFeatures,
                knowledgeIntegrations: knowledgeIntegrations,
                permissionHandler: permissionHandler
            )
        }
    }

    func authenticate(methodId: String) {
        queue.async { [weak self] in
            guard let self,
                  self.process != nil,
                  self.authenticationMethods.contains(where: { $0.id == methodId }) else {
                return
            }
            self.statusPromise.set(.connecting)
            self.sendRequest(method: "authenticate", params: ["methodId": methodId]) { [weak self] response in
                guard let self else { return }
                if let error = response["error"] as? [String: Any] {
                    self.stopOnQueue(status: .failed(error["message"] as? String ?? "ACP authentication failed"))
                } else {
                    self.createSessionOnQueue()
                }
            }
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

    private func connectOnQueue(
        configuration: WorkspaceACPConfiguration,
        enabledFeatures: [WorkspaceAIFeature],
        knowledgeIntegrations: [WorkspaceKnowledgeIntegration],
        permissionHandler: @escaping WorkspaceACPPermissionHandler
    ) {
        stopOnQueue(status: .connecting)
        statusPromise.set(.connecting)

        guard FileManager.default.fileExists(atPath: configuration.workingDirectory) else {
            statusPromise.set(.failed("Working directory does not exist"))
            return
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: configuration.executable)
        process.arguments = configuration.launchArguments
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
            self.configuration = configuration
            self.permissionHandler = permissionHandler
            self.knowledgeIntegrations = knowledgeIntegrations
            sendRequest(method: "initialize", params: [
                "protocolVersion": 1,
                "clientCapabilities": [
                    "_meta": [
                        "dev.telegramwork/aiFeatures": enabledFeatures.map { feature in
                            [
                                "id": feature.rawValue,
                                "title": feature.title,
                                "access": feature.isWriteCapability ? "write" : "read"
                            ]
                        }
                    ]
                ],
                "clientInfo": [
                    "name": "telegramwork-mac",
                    "title": "TelegramWork for macOS",
                    "version": APP_VERSION_STRING
                ]
            ]) { [weak self] response in
                guard let self else { return }
                if let error = response["error"] as? [String: Any] {
                    self.stopOnQueue(status: .failed(error["message"] as? String ?? "ACP initialization failed"))
                    return
                }
                let result = response["result"] as? [String: Any]
                guard let protocolVersion = result?["protocolVersion"] as? Int, protocolVersion == 1 else {
                    self.stopOnQueue(status: .failed("Agent does not support ACP v1"))
                    return
                }
                let info = result?["agentInfo"] as? [String: Any]
                self.agentName = (info?["title"] as? String) ?? (info?["name"] as? String) ?? configuration.provider.title
                self.authenticationMethods = (result?["authMethods"] as? [[String: Any]] ?? []).compactMap { method in
                    guard let id = method["id"] as? String else { return nil }
                    return WorkspaceACPAuthMethod(
                        id: id,
                        name: (method["name"] as? String) ?? id,
                        description: method["description"] as? String
                    )
                }
                self.createSessionOnQueue()
            }
        } catch {
            stopOnQueue(status: .failed(error.localizedDescription))
        }
    }

    private func createSessionOnQueue() {
        guard let configuration else {
            stopOnQueue(status: .failed("ACP configuration is missing"))
            return
        }
        sendRequest(method: "session/new", params: [
            "cwd": configuration.workingDirectory,
            "mcpServers": mcpServersForActiveIntegrations()
        ]) { [weak self] response in
            guard let self else { return }
            if let error = response["error"] as? [String: Any] {
                let message = error["message"] as? String ?? "ACP session creation failed"
                let normalizedMessage = message.lowercased()
                if !self.authenticationMethods.isEmpty,
                   (normalizedMessage.contains("auth") || normalizedMessage.contains("login") || normalizedMessage.contains("sign in")) {
                    self.statusPromise.set(.authenticationRequired(
                        agentName: self.agentName ?? configuration.provider.title,
                        methods: self.authenticationMethods
                    ))
                } else {
                    self.stopOnQueue(status: .failed(message))
                }
                return
            }
            guard let result = response["result"] as? [String: Any], let sessionId = result["sessionId"] as? String else {
                self.stopOnQueue(status: .failed("ACP agent returned no session ID"))
                return
            }
            self.sessionId = sessionId
            self.modelUsesConfigOption = WorkspaceACPClient.usesConfigOptionForModel(result)
            self.modelsPromise.set(WorkspaceACPClient.parseModels(from: result))
            self.currentModelPromise.set(WorkspaceACPClient.parseCurrentModel(from: result))
            self.statusPromise.set(.connected(agentName: self.agentName ?? configuration.provider.title))
        }
    }

    /// ACP agents report their model list in more than one shape, so accept either a bare array
    /// or an object wrapping one, and tolerate both `modelId` and `id` spellings.
    private static func parseCurrentModel(from result: [String: Any]) -> String {
        if let object = result["models"] as? [String: Any], let current = object["currentModelId"] as? String {
            return current
        }
        if let current = result["currentModelId"] as? String {
            return current
        }
        return (modelConfigOption(in: result)?["currentValue"] as? String) ?? ""
    }

    /// Whether the agent drives model selection through `configOptions` rather than `models`.
    private static func usesConfigOptionForModel(_ result: [String: Any]) -> Bool {
        return (result["models"] == nil) && modelConfigOption(in: result) != nil
    }

    /// The `configOptions` entry an agent uses for model selection, when it has one.
    private static func modelConfigOption(in result: [String: Any]) -> [String: Any]? {
        guard let options = result["configOptions"] as? [[String: Any]] else { return nil }
        return options.first(where: { ($0["id"] as? String) == "model" || ($0["category"] as? String) == "model" })
    }

    /// Two agents, two shapes. codex-acp answers `session/new` with `models.availableModels`,
    /// where the reasoning effort is already folded into each id (`gpt-5.6-sol[high]`);
    /// opencode instead lists a `configOptions` entry whose id is `model`. Read both.
    private static func parseModels(from result: [String: Any]) -> [WorkspaceACPModel] {
        func mapped(_ entries: [[String: Any]]) -> [WorkspaceACPModel] {
            return entries.compactMap { entry in
                guard let id = (entry["modelId"] as? String) ?? (entry["id"] as? String), !id.isEmpty else {
                    return nil
                }
                let name = (entry["name"] as? String) ?? (entry["displayName"] as? String) ?? id
                return WorkspaceACPModel(id: id, name: name)
            }
        }
        if let object = result["models"] as? [String: Any],
           let available = object["availableModels"] as? [[String: Any]] {
            return mapped(available)
        }
        if let array = result["models"] as? [[String: Any]] {
            return mapped(array)
        }
        guard let options = modelConfigOption(in: result)?["options"] as? [[String: Any]] else {
            return []
        }
        return options.compactMap { entry in
            guard let value = entry["value"] as? String, !value.isEmpty else { return nil }
            return WorkspaceACPModel(id: value, name: (entry["name"] as? String) ?? value)
        }
    }

    private func stopOnQueue(status: WorkspaceACPStatus) {
        let current = process
        process = nil
        input = nil
        pending.removeAll()
        sessionId = nil
        configuration = nil
        modelsPromise.set([])
        currentModelPromise.set("")
        agentName = nil
        authenticationMethods = []
        permissionHandler = nil
        knowledgeIntegrations = []
        outputBuffer.removeAll(keepingCapacity: false)
        current?.standardOutput.flatMap { ($0 as? Pipe)?.fileHandleForReading.readabilityHandler = nil }
        current?.standardError.flatMap { ($0 as? Pipe)?.fileHandleForReading.readabilityHandler = nil }
        if current?.isRunning == true {
            current?.terminate()
        }
        statusPromise.set(status)
    }

    private func mcpServersForActiveIntegrations() -> [[String: Any]] {
        guard let scriptPath = Bundle.main.path(forResource: "telegramwork_knowledge_mcp", ofType: "py") else {
            return []
        }
        return knowledgeIntegrations.compactMap { integration in
            guard integration.isEnabled, integration.exposesCodexTools, integration.hasValidRoot else {
                return nil
            }
            return [
                "name": "\(integration.kind.title): \(integration.name)",
                "command": "/usr/bin/python3",
                "args": [scriptPath, "--root", integration.expandedRootPath],
                "env": [[
                    "name": "TELEGRAMWORK_INTEGRATION_INSTRUCTIONS",
                    "value": integration.instructions
                ]]
            ]
        }
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
        if method == "session/request_permission", let params {
            let toolCall = params["toolCall"] as? [String: Any]
            let title = (toolCall?["title"] as? String) ?? "The AI agent wants to use a tool."
            let options = (params["options"] as? [[String: Any]] ?? []).compactMap { option -> WorkspaceACPPermissionOption? in
                guard let optionId = option["optionId"] as? String,
                      let name = option["name"] as? String,
                      let kind = option["kind"] as? String else {
                    return nil
                }
                return WorkspaceACPPermissionOption(id: optionId, name: name, kind: kind)
            }
            guard let permissionHandler else {
                write(["jsonrpc": "2.0", "id": id, "result": ["outcome": ["outcome": "cancelled"]]])
                return
            }
            permissionHandler(title, options) { [weak self] optionId in
                self?.queue.async {
                    guard let self else { return }
                    if let optionId {
                        self.write(["jsonrpc": "2.0", "id": id, "result": ["outcome": ["outcome": "selected", "optionId": optionId]]])
                    } else {
                        self.write(["jsonrpc": "2.0", "id": id, "result": ["outcome": ["outcome": "cancelled"]]])
                    }
                }
            }
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
            return "ACP agent is not connected"
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

enum WorkspaceMessageSender {
    static func send(context: AccountContext, peerId: PeerId, text: String) -> Signal<[MessageId?], NoError> {
        let message = EnqueueMessage.message(
            text: text,
            attributes: [],
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
private let workspaceACPModelId = InputDataIdentifier("workspace.acp.model")
private let workspaceTranscriptionEndpointId = InputDataIdentifier("workspace.transcription.endpoint")
private let workspaceTranscriptionModelId = InputDataIdentifier("workspace.transcription.model")
private let workspaceACPArgumentsId = InputDataIdentifier("workspace.acp.arguments")
private let workspaceACPDirectoryId = InputDataIdentifier("workspace.acp.directory")

private func workspaceIntegrationPathId(_ integrationId: String) -> InputDataIdentifier {
    return InputDataIdentifier("workspace.integration.\(integrationId).path")
}

private func workspaceIntegrationInstructionsId(_ integrationId: String) -> InputDataIdentifier {
    return InputDataIdentifier("workspace.integration.\(integrationId).instructions")
}

private func workspaceProfileEntries(
    context: AccountContext,
    state: WorkspaceProfileState,
    filters: [ChatListFilter],
    acpStatus: WorkspaceACPStatus,
    acpModels: [WorkspaceACPModel],
    acpCurrentModel: String,
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
    for (position, profile) in state.profiles.enumerated() {
        entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: InputDataIdentifier("workspace.profile.\(profile.id)"), data: .init(
            name: profile.name,
            color: theme.colors.text,
            type: .selectable(profile.id == state.activeProfileId),
            viewType: position == 0 ? .firstItem : .innerItem,
            action: { store.activate(profile.id) },
            menuItems: profile.kind == .custom ? {
                return [ContextMenuItem("Delete Profile", handler: { store.remove(profile.id) }, itemMode: .destruct)]
            } : nil
        )))
        index += 1
    }
    entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: InputDataIdentifier("workspace.profile.add"), data: .init(name: "Add Custom Profile", color: theme.colors.accent, type: .none, viewType: state.profiles.isEmpty ? .singleItem : .lastItem, action: store.addCustomProfile)))
    index += 1

    entries.append(.sectionId(sectionId, type: .normal))
    sectionId += 1
    let active = state.activeProfile
    if active.kind == .custom {
        entries.append(.input(sectionId: sectionId, index: index, value: .string(active.name), error: nil, identifier: workspaceProfileNameId, mode: .plain, data: .init(viewType: .firstItem), placeholder: nil, inputPlaceholder: "Profile name", filter: { $0 }, limit: 64))
        index += 1
    }
    entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: InputDataIdentifier("workspace.notifications"), data: .init(name: "Receive Notifications", color: theme.colors.text, type: .switchable(active.receivesNotifications), viewType: active.kind == .custom ? .innerItem : .firstItem, action: {
        store.updateActive { $0.receivesNotifications.toggle() }
    }, autoswitch: false)))
    index += 1
    entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: InputDataIdentifier("workspace.stories"), data: .init(name: "Show Stories", color: theme.colors.text, type: .switchable(active.showsStories), viewType: .innerItem, action: {
        store.updateActive { $0.showsStories.toggle() }
    }, autoswitch: false)))
    index += 1
    let profileChatCount = active.includedPeerIds.count
    entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: InputDataIdentifier("workspace.chats"), data: .init(name: "Profile Chats", color: theme.colors.text, type: .nextContext(profileChatCount == 0 ? "None" : "\(profileChatCount)"), viewType: .lastItem, action: {
        let selectedPeerIds = Set(active.includedPeerIds.map(PeerId.init))
        let behavior = SelectChatsBehavior(settings: [.contacts, .remote, .groups, .channels, .bots], excludePeerIds: [], limit: 200)
        _ = selectModalPeers(
            window: context.window,
            context: context,
            title: "Chats in \(active.name)",
            settings: [.contacts, .remote, .groups, .channels, .bots],
            excludePeerIds: [],
            limit: 200,
            behavior: behavior,
            selectedPeerIds: selectedPeerIds,
            okTitle: strings().modalOK
        ).start(next: { peerIds in
            store.updateActive { profile in
                profile.includedPeerIds = peerIds.map { $0.toInt64() }
            }
        })
    })))
    index += 1
    entries.append(.desc(sectionId: sectionId, index: index, text: .plain("Selected chats appear in a dedicated profile tab and are always included in this profile's folder views. If chats are selected, profile notifications are limited to them."), data: .init(color: theme.colors.listGrayText, viewType: .textBottomItem)))
    index += 1

    entries.append(.sectionId(sectionId, type: .normal))
    sectionId += 1
    entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: InputDataIdentifier("workspace.folders.all"), data: .init(name: "Show All Chat Folders", color: theme.colors.text, type: .switchable(active.showsAllFolders), viewType: .singleItem, action: {
        store.updateActive { $0.showsAllFolders.toggle() }
    }, autoswitch: false)))
    index += 1
    if !active.showsAllFolders {
        entries.append(.desc(sectionId: sectionId, index: index, text: .plain("VISIBLE CHAT FOLDERS"), data: .init(color: theme.colors.listGrayText, detectBold: true, viewType: .textTopItem)))
        index += 1
        for (position, filter) in filters.enumerated() {
            entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: InputDataIdentifier("workspace.folder.\(filter.id)"), data: .init(name: filter.title, color: theme.colors.text, type: .switchable(active.visibleFolderIds.contains(filter.id)), viewType: bestGeneralViewType(filters, for: position), action: {
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
    entries.append(.desc(sectionId: sectionId, index: index, text: .plain("CHAT ACTIONS"), data: .init(color: theme.colors.listGrayText, detectBold: true, viewType: .textTopItem)))
    index += 1
    let chatActions = CodexAssistantAction.configurable
    for (position, chatAction) in chatActions.enumerated() {
        entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: InputDataIdentifier("workspace.\(chatAction.flagKey)"), data: .init(
            name: chatAction.title,
            color: theme.colors.text,
            type: .switchable(active.isEnabled(chatAction)),
            /// The range row closes this block, so no action row is ever `.lastItem`.
            viewType: position == 0 ? .firstItem : .innerItem,
            description: chatAction.settingsSubtitle,
            action: {
                store.updateActive { profile in
                    profile.featureFlags[chatAction.flagKey] = !profile.isEnabled(chatAction)
                }
            },
            autoswitch: false
        )))
        index += 1
    }
    entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: InputDataIdentifier("workspace.chat.range"), data: .init(
        name: "Range When Not Today",
        color: theme.colors.text,
        type: .nextContext(active.chatRangePreset.title),
        viewType: chatActions.isEmpty ? .singleItem : .lastItem,
        description: "How far back the panel looks once you clear Today",
        action: {
            store.updateActive { profile in
                let values = WorkspaceChatRangePreset.allCases
                let current = values.firstIndex(of: profile.chatRangePreset) ?? 0
                profile.chatRangePreset = values[(current + 1) % values.count]
            }
        }
    )))
    index += 1
    entries.append(.desc(sectionId: sectionId, index: index, text: .plain("Which buttons appear in the agent panel inside a chat, and how far back it looks when you clear the Today checkbox. Voice to text and Generate image are off until you turn them on."), data: .init(color: theme.colors.listGrayText, viewType: .textBottomItem)))
    index += 1

    if active.isEnabled(.voiceToText) {
        entries.append(.sectionId(sectionId, type: .normal))
        sectionId += 1
        entries.append(.desc(sectionId: sectionId, index: index, text: .plain("LOCAL TRANSCRIPTION"), data: .init(color: theme.colors.listGrayText, detectBold: true, viewType: .textTopItem)))
        index += 1
        entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: InputDataIdentifier("workspace.transcription.enabled"), data: .init(
            name: "Use a Local Model",
            color: theme.colors.text,
            type: .switchable(active.localTranscription.isEnabled),
            viewType: active.localTranscription.isEnabled ? .firstItem : .singleItem,
            description: "Send voice notes to a speech-to-text server on this Mac instead of Telegram",
            action: {
                store.updateActive { $0.localTranscription.isEnabled.toggle() }
            },
            autoswitch: false
        )))
        index += 1
        if active.localTranscription.isEnabled {
            entries.append(.input(sectionId: sectionId, index: index, value: .string(active.localTranscription.endpoint), error: nil, identifier: workspaceTranscriptionEndpointId, mode: .plain, data: .init(viewType: .innerItem), placeholder: InputDataInputPlaceholder("Endpoint"), inputPlaceholder: "http://127.0.0.1:8080/v1/audio/transcriptions", filter: { $0 }, limit: 1024))
            index += 1
            entries.append(.input(sectionId: sectionId, index: index, value: .string(active.localTranscription.model), error: nil, identifier: workspaceTranscriptionModelId, mode: .plain, data: .init(viewType: .lastItem), placeholder: InputDataInputPlaceholder("Model"), inputPlaceholder: "whisper-1", filter: { $0 }, limit: 256))
            index += 1
        }
        entries.append(.desc(sectionId: sectionId, index: index, text: .plain("Works with any OpenAI-compatible transcription server — whisper.cpp, faster-whisper-server, LocalAI, Speaches. Audio never leaves this Mac and Telegram Premium is not required. When this is off, Voice to text uses Telegram's own transcription, which needs Premium."), data: .init(color: theme.colors.listGrayText, viewType: .textBottomItem)))
        index += 1
    }


    entries.append(.sectionId(sectionId, type: .normal))
    sectionId += 1
    entries.append(.desc(sectionId: sectionId, index: index, text: .plain("KNOWLEDGE INTEGRATIONS"), data: .init(color: theme.colors.listGrayText, detectBold: true, viewType: .textTopItem)))
    index += 1
    if active.knowledgeIntegrations.isEmpty {
        entries.append(.desc(sectionId: sectionId, index: index, text: .plain("Connect local knowledge to this profile. Add a vault, provide its folder path and plain-language instructions, and TelegramWork configures both local retrieval and agent tools."), data: .init(color: theme.colors.listGrayText, viewType: .textBottomItem)))
        index += 1
    }
    for integration in active.knowledgeIntegrations {
        entries.append(.desc(sectionId: sectionId, index: index, text: .plain(integration.kind.title.uppercased()), data: .init(color: theme.colors.listGrayText, detectBold: true, viewType: .textTopItem)))
        index += 1
        entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: InputDataIdentifier("workspace.integration.\(integration.id).enabled"), data: .init(name: "Enabled", color: theme.colors.text, type: .switchable(integration.isEnabled), viewType: .firstItem, action: {
            store.updateActive { profile in
                guard let position = profile.knowledgeIntegrations.firstIndex(where: { $0.id == integration.id }) else { return }
                profile.knowledgeIntegrations[position].isEnabled.toggle()
            }
        }, autoswitch: false)))
        index += 1
        entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: InputDataIdentifier("workspace.integration.\(integration.id).local-search"), data: .init(name: "Search Notes for Every Request", color: theme.colors.text, type: .switchable(integration.usesLocalSearch), viewType: .innerItem, action: {
            store.updateActive { profile in
                guard let position = profile.knowledgeIntegrations.firstIndex(where: { $0.id == integration.id }) else { return }
                profile.knowledgeIntegrations[position].usesLocalSearch.toggle()
            }
        }, autoswitch: false)))
        index += 1
        entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: InputDataIdentifier("workspace.integration.\(integration.id).codex-tools"), data: .init(name: "Expose Read-Only Tools to the Agent", color: theme.colors.text, type: .switchable(integration.exposesCodexTools), viewType: .lastItem, action: {
            client.disconnect()
            store.updateActive { profile in
                guard let position = profile.knowledgeIntegrations.firstIndex(where: { $0.id == integration.id }) else { return }
                profile.knowledgeIntegrations[position].exposesCodexTools.toggle()
            }
        }, autoswitch: false)))
        index += 1

        entries.append(.sectionId(sectionId, type: .normal))
        sectionId += 1
        entries.append(.input(sectionId: sectionId, index: index, value: .string(integration.rootPath), error: nil, identifier: workspaceIntegrationPathId(integration.id), mode: .plain, data: .init(viewType: .firstItem), placeholder: nil, inputPlaceholder: "Obsidian vault folder path", filter: { $0 }, limit: 4096))
        index += 1
        entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: InputDataIdentifier("workspace.integration.\(integration.id).choose"), data: .init(name: "Choose Vault Folder…", color: theme.colors.accent, type: .next, viewType: .innerItem, action: {
            filePanel(with: [], canChooseDirectories: true, for: context.window, completion: { paths in
                guard let path = paths?.first else { return }
                client.disconnect()
                store.updateActive { profile in
                    guard let position = profile.knowledgeIntegrations.firstIndex(where: { $0.id == integration.id }) else { return }
                    profile.knowledgeIntegrations[position].rootPath = path
                }
            })
        })))
        index += 1
        entries.append(.input(sectionId: sectionId, index: index, value: .string(integration.instructions), error: nil, identifier: workspaceIntegrationInstructionsId(integration.id), mode: .plain, data: .init(viewType: .lastItem), placeholder: nil, inputPlaceholder: "Instructions for the agent", filter: { $0 }, limit: 4096))
        index += 1
        let integrationStatus: String
        if integration.rootPath.isEmpty {
            integrationStatus = "Choose your Obsidian vault folder. Instructions describe how the agent should interpret and cite this knowledge."
        } else if integration.hasValidRoot {
            integrationStatus = "Ready · Markdown only · local search and bundled MCP access are read-only. Reconnect the agent after changing this integration."
        } else {
            integrationStatus = "Vault folder is unavailable. Check the path or choose the folder again."
        }
        entries.append(.desc(sectionId: sectionId, index: index, text: .plain(integrationStatus), data: .init(color: theme.colors.listGrayText, viewType: .textBottomItem)))
        index += 1

        entries.append(.sectionId(sectionId, type: .normal))
        sectionId += 1
        entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: InputDataIdentifier("workspace.integration.\(integration.id).remove"), data: .init(name: "Remove \(integration.kind.title)", color: theme.colors.redUI, type: .none, viewType: .singleItem, action: {
            client.disconnect()
            store.removeIntegration(integration.id)
        })))
        index += 1
    }

    entries.append(.sectionId(sectionId, type: .normal))
    sectionId += 1
    entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: InputDataIdentifier("workspace.integration.add.obsidian"), data: .init(name: "Add Obsidian Vault", color: theme.colors.accent, type: .none, viewType: .singleItem, action: {
        client.disconnect()
        store.addObsidianIntegration()
    })))
    index += 1

    entries.append(.sectionId(sectionId, type: .normal))
    sectionId += 1
    entries.append(.desc(sectionId: sectionId, index: index, text: .plain("AI AGENT · AGENT CLIENT PROTOCOL"), data: .init(color: theme.colors.listGrayText, detectBold: true, viewType: .textTopItem)))
    index += 1
    let providers = WorkspaceACPProvider.allCases
    for (position, provider) in providers.enumerated() {
        entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: InputDataIdentifier("workspace.acp.provider.\(provider.rawValue)"), data: .init(
            name: provider.title,
            color: theme.colors.text,
            type: .selectable(provider == state.acp.provider),
            viewType: bestGeneralViewType(providers, for: position),
            action: {
                client.disconnect()
                store.updateACP { $0.selectProvider(provider) }
            }
        )))
        index += 1
    }

    entries.append(.sectionId(sectionId, type: .normal))
    sectionId += 1
    entries.append(.desc(sectionId: sectionId, index: index, text: .plain("AGENT COMMAND"), data: .init(color: theme.colors.listGrayText, detectBold: true, viewType: .textTopItem)))
    index += 1
    entries.append(.input(sectionId: sectionId, index: index, value: .string(state.acp.executable), error: nil, identifier: workspaceACPExecutableId, mode: .plain, data: .init(viewType: .firstItem), placeholder: InputDataInputPlaceholder("Program"), inputPlaceholder: "ACP executable", filter: { $0 }, limit: 1024))
    index += 1
    entries.append(.input(sectionId: sectionId, index: index, value: .string(state.acp.arguments.joined(separator: " ")), error: nil, identifier: workspaceACPArgumentsId, mode: .plain, data: .init(viewType: .innerItem), placeholder: InputDataInputPlaceholder("Arguments"), inputPlaceholder: "Arguments", filter: { $0 }, limit: 2048))
    index += 1
    entries.append(.input(sectionId: sectionId, index: index, value: .string(state.acp.workingDirectory), error: nil, identifier: workspaceACPDirectoryId, mode: .plain, data: .init(viewType: .innerItem), placeholder: InputDataInputPlaceholder("Folder"), inputPlaceholder: "Working directory", filter: { $0 }, limit: 2048))
    index += 1
    /// Prefer what the connected agent reported; fall back to the provider's known list.
    let offered = !acpModels.isEmpty
        ? acpModels
        : state.acp.provider.suggestedModels.map { WorkspaceACPModel(id: $0, name: $0) }
    /// While connected the agent's own current model wins; otherwise show what will be requested.
    let effectiveModel = acpCurrentModel.isEmpty ? state.acp.model : acpCurrentModel
    var modelValues: [ValuesSelectorValue<InputDataValue>] = [
        ValuesSelectorValue(localized: "Agent default", value: .string(""))
    ]
    modelValues.append(contentsOf: offered.map { ValuesSelectorValue(localized: $0.name, value: .string($0.id)) })
    /// A model the agent has since stopped listing must still be shown as the current choice.
    if !effectiveModel.isEmpty, !offered.contains(where: { $0.id == effectiveModel }) {
        modelValues.append(ValuesSelectorValue(localized: effectiveModel, value: .string(effectiveModel)))
    }
    entries.append(.selector(sectionId: sectionId, index: index, value: .string(effectiveModel), error: nil, identifier: workspaceACPModelId, placeholder: "Model", viewType: .lastItem, values: modelValues))
    index += 1
    let acpHint: String
    if state.acp.provider == .custom {
        acpHint = "The program TelegramWork starts to run this agent, the folder it treats as its project root, and the model to request. Enter the command for your own ACP agent here. The model list is read from the agent once it connects."
    } else {
        acpHint = "The program TelegramWork starts to run \(state.acp.provider.title), the folder it treats as its project root, and the model to request. The model list is read from the agent once it connects; the rest is filled in for you."
    }
    entries.append(.desc(sectionId: sectionId, index: index, text: .plain(acpHint), data: .init(color: theme.colors.listGrayText, viewType: .textBottomItem)))
    index += 1

    entries.append(.sectionId(sectionId, type: .normal))
    sectionId += 1
    entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: InputDataIdentifier("workspace.acp.auto-connect"), data: .init(name: "Connect Agent Automatically", color: theme.colors.text, type: .switchable(state.acp.autoConnect), viewType: .firstItem, action: {
        let wasEnabled = store.current.acp.autoConnect
        store.updateACP { $0.autoConnect.toggle() }
        if wasEnabled {
            client.disconnect()
        }
    }, autoswitch: false)))
    index += 1
    let isConnected: Bool
    switch acpStatus {
    case .connected, .connecting, .authenticationRequired:
        isConnected = true
    default:
        isConnected = false
    }
    entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: InputDataIdentifier("workspace.acp.connect"), data: .init(name: isConnected ? "Disconnect Agent" : "Connect to \(state.acp.provider.title)", color: theme.colors.accent, type: .nextContext(acpStatus.title), viewType: .lastItem, action: {
        if isConnected {
            store.updateACP { $0.autoConnect = false }
            client.disconnect()
        } else {
            let current = store.current
            let features = current.activeProfile.advertisedFeatures
            client.connect(configuration: current.acp, enabledFeatures: features, knowledgeIntegrations: current.activeProfile.knowledgeIntegrations, permissionHandler: { title, options, completion in
                DispatchQueue.main.async {
                    guard let allow = options.first(where: { $0.kind == "allow_once" }) ?? options.first(where: { $0.kind == "allow_always" }) else {
                        completion(options.first(where: { $0.kind == "reject_once" || $0.kind == "reject_always" })?.id)
                        return
                    }
                    let reject = options.first(where: { $0.kind == "reject_once" }) ?? options.first(where: { $0.kind == "reject_always" })
                    verifyAlert_button(
                        for: context.window,
                        header: "AI Agent Permission",
                        information: title,
                        ok: allow.name,
                        cancel: reject?.name ?? strings().modalCancel,
                        successHandler: { _ in completion(allow.id) },
                        cancelHandler: { completion(reject?.id) }
                    )
                }
            })
        }
    })))
    index += 1
    if case let .authenticationRequired(_, methods) = acpStatus {
        for method in methods {
            entries.append(.sectionId(sectionId, type: .normal))
            sectionId += 1
            entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: InputDataIdentifier("workspace.acp.auth.\(method.id)"), data: .init(name: "Sign in with \(method.name)", color: theme.colors.accent, type: .none, viewType: .singleItem, action: {
                client.authenticate(methodId: method.id)
            })))
            index += 1
            if let description = method.description {
                entries.append(.desc(sectionId: sectionId, index: index, text: .plain(description), data: .init(color: theme.colors.listGrayText, viewType: .textBottomItem)))
                index += 1
            }
        }
    }
    entries.append(.sectionId(sectionId, type: .normal))
    sectionId += 1
    return entries
}

func WorkspaceProfilesController(context: AccountContext) -> InputDataController {
    let accountId = context.account.id.int64
    let store = WorkspaceProfileStore.shared(accountId: accountId)
    let client = WorkspaceACPRegistry.shared.client(accountId: accountId)
    let filters = chatListFilterPreferences(engine: context.engine) |> map { $0.list }
    let signal = combineLatest(queue: prepareQueue, appearanceSignal, store.signal, filters, client.status, client.models, client.currentModel)
    |> map { _, state, filters, acpStatus, acpModels, acpCurrentModel in
        return InputDataSignalValue(entries: workspaceProfileEntries(context: context, state: state, filters: filters, acpStatus: acpStatus, acpModels: acpModels, acpCurrentModel: acpCurrentModel, store: store, client: client))
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
            if let arguments = data[workspaceACPArgumentsId]?.stringValue {
                configuration.arguments = arguments.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            }
            if let directory = data[workspaceACPDirectoryId]?.stringValue, !directory.isEmpty {
                configuration.workingDirectory = directory
            }
        }
        if let model = data[workspaceACPModelId]?.stringValue, model != store.current.acp.model {
            store.updateACP { $0.model = model }
            /// Switch the live session in place when the agent supports it.
            if !model.isEmpty {
                client.selectModel(model)
            }
        }
        store.updateActive { profile in
            if let endpoint = data[workspaceTranscriptionEndpointId]?.stringValue {
                profile.localTranscription.endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let model = data[workspaceTranscriptionModelId]?.stringValue {
                profile.localTranscription.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        let currentIntegrations = store.current.activeProfile.knowledgeIntegrations
        if !currentIntegrations.isEmpty {
            let integrationChanged = currentIntegrations.contains { integration in
                let path = data[workspaceIntegrationPathId(integration.id)]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                let instructions = data[workspaceIntegrationInstructionsId(integration.id)]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                return (path != nil && path != integration.rootPath) || (instructions != nil && instructions != integration.instructions)
            }
            if integrationChanged {
                client.disconnect()
            }
            store.updateActive { profile in
                for position in profile.knowledgeIntegrations.indices {
                    let id = profile.knowledgeIntegrations[position].id
                    if let path = data[workspaceIntegrationPathId(id)]?.stringValue {
                        profile.knowledgeIntegrations[position].rootPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    if let instructions = data[workspaceIntegrationInstructionsId(id)]?.stringValue {
                        profile.knowledgeIntegrations[position].instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }
        }
        return .none
    }
    controller.validateData = { _ in .none }
    return controller
}
