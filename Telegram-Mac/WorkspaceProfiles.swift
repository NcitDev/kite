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
    /// Per-action model override. Lives here because model ids are agent-specific.
    var actionModels: [String: String]

    /// Model an action should run on: its own override when set, otherwise this agent's model.
    func resolvedModel(for action: CodexAssistantAction) -> String {
        let override = actionModels[action.rawValue] ?? ""
        return override.isEmpty ? model : override
    }

    static var defaultValue: WorkspaceACPConfiguration {
        return WorkspaceACPConfiguration(
            provider: .codex,
            executable: "/usr/bin/env",
            arguments: WorkspaceACPProvider.codex.defaultArguments,
            workingDirectory: NSHomeDirectory(),
            autoConnect: true,
            model: WorkspaceACPProvider.codex.defaultModel,
            actionModels: [:]
        )
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
        case actionModels
    }

    init(provider: WorkspaceACPProvider, executable: String, arguments: [String], workingDirectory: String, autoConnect: Bool, model: String, actionModels: [String: String]) {
        self.provider = provider
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.autoConnect = autoConnect
        self.model = model
        self.actionModels = actionModels
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
            model: try container.decodeIfPresent(String.self, forKey: .model) ?? provider.defaultModel,
            actionModels: try container.decodeIfPresent([String: String].self, forKey: .actionModels) ?? [:]
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
    /// The agent currently in use.
    var acp: WorkspaceACPConfiguration
    /// One saved setup per agent, so switching agents restores rather than resets.
    var acpProfiles: [String: WorkspaceACPConfiguration]

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
            acp: .defaultValue,
            acpProfiles: [:]
        )
    }

    /// Saves the agent in use, then swaps in the saved setup for `provider` — creating a fresh
    /// one from that provider's defaults the first time it is selected.
    mutating func selectACPProvider(_ provider: WorkspaceACPProvider) {
        guard provider != acp.provider else { return }
        acpProfiles[acp.provider.rawValue] = acp
        let autoConnect = acp.autoConnect
        let workingDirectory = acp.workingDirectory
        if var saved = acpProfiles[provider.rawValue] {
            saved.autoConnect = autoConnect
            acp = saved
        } else {
            var fresh = WorkspaceACPConfiguration.defaultValue
            fresh.selectProvider(provider)
            fresh.autoConnect = autoConnect
            fresh.workingDirectory = workingDirectory
            acp = fresh
        }
    }

    var activeProfile: WorkspaceProfile {
        return profiles.first(where: { $0.id == activeProfileId }) ?? profiles.first ?? WorkspaceProfileState.defaultValue.profiles[0]
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case activeProfileId
        case profiles
        case acp
        case acpProfiles
    }

    init(schemaVersion: Int, activeProfileId: String, profiles: [WorkspaceProfile], acp: WorkspaceACPConfiguration, acpProfiles: [String: WorkspaceACPConfiguration]) {
        self.schemaVersion = schemaVersion
        self.activeProfileId = activeProfileId
        self.profiles = profiles
        self.acp = acp
        self.acpProfiles = acpProfiles
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 3
        self.activeProfileId = try container.decode(String.self, forKey: .activeProfileId)
        self.profiles = try container.decode([WorkspaceProfile].self, forKey: .profiles)
        self.acp = try container.decodeIfPresent(WorkspaceACPConfiguration.self, forKey: .acp) ?? .defaultValue
        self.acpProfiles = try container.decodeIfPresent([String: WorkspaceACPConfiguration].self, forKey: .acpProfiles) ?? [:]
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

    func selectACPProvider(_ provider: WorkspaceACPProvider) {
        update { state in
            state.selectACPProvider(provider)
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
    /// The model the agent last confirmed it is running, so a rejected switch can fall back
    /// to the truth rather than leaving the UI showing a model that never took effect.
    private var reportedModel = ""
    /// A GUI app launched by launchd inherits only `/usr/bin:/bin:/usr/sbin:/sbin`, so the
    /// package managers agents are installed with — Homebrew, bun, npm, nvm — are invisible to
    /// it and `/usr/bin/env <agent>` fails. Put the usual install locations back on PATH.
    static func agentSearchPath() -> [String] {
        var combined: [String] = []
        var seen = Set<String>()
        func add(_ directory: String) {
            let path = directory.trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty, seen.insert(path).inserted else { return }
            combined.append(path)
        }
        /// The login shell reflects what this particular user actually configured, so it comes
        /// first and covers install locations no hardcoded list could know about.
        (loginShellEnvironment["PATH"] ?? "").components(separatedBy: ":").forEach(add)
        knownAgentDirectories().filter { FileManager.default.fileExists(atPath: $0) }.forEach(add)
        (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            .components(separatedBy: ":")
            .forEach(add)
        return combined
    }

    /// Variables that describe the probe shell's own session rather than the user's setup;
    /// carrying them into the agent would point it at the wrong directory.
    private static let sessionLocalVariables: Set<String> = ["PWD", "OLDPWD", "SHLVL", "_"]

    static func agentEnvironment(searchPath: [String]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        /// Agents read their credentials from the environment, and users export those in the
        /// same shell profile that sets up PATH. Inheriting the whole thing is what makes the
        /// agent behave the way it does when the user runs it in a terminal themselves.
        for (key, value) in loginShellEnvironment where !sessionLocalVariables.contains(key) {
            environment[key] = value
        }
        /// The agent spawns its own tooling, so it needs the widened PATH too, not just us.
        environment["PATH"] = searchPath.joined(separator: ":")
        return environment
    }

    /// Bin directories the common package managers use. Version managers get a directory scan
    /// because they keep one bin directory per installed runtime version.
    private static func knownAgentDirectories() -> [String] {
        let home = NSHomeDirectory()
        var directories = [
            "\(home)/.bun/bin",
            "\(home)/.local/bin",
            "\(home)/.opencode/bin",
            "\(home)/.volta/bin",
            "\(home)/.asdf/shims",
            "\(home)/.mise/shims",
            "\(home)/.local/share/mise/shims",
            "\(home)/.npm-global/bin",
            "\(home)/.npm-packages/bin",
            "\(home)/.yarn/bin",
            "\(home)/Library/pnpm",
            "\(home)/.cargo/bin",
            "\(home)/go/bin",
            "\(home)/.nix-profile/bin",
            "/nix/var/nix/profiles/default/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/opt/local/bin"
        ]
        directories.append(contentsOf: versionedDirectories(in: "\(home)/.nvm/versions/node", suffix: "bin"))
        directories.append(contentsOf: versionedDirectories(in: "\(home)/.fnm/node-versions", suffix: "installation/bin"))
        directories.append(contentsOf: versionedDirectories(in: "\(home)/Library/Application Support/fnm/node-versions", suffix: "installation/bin"))
        return directories
    }

    private static func versionedDirectories(in root: String, suffix: String) -> [String] {
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: root) else {
            return []
        }
        return versions.sorted().reversed().map { "\(root)/\($0)/\(suffix)" }
    }

    /// The environment the user's own shell would give the agent, read once: spawning a shell
    /// is not free, and startup files do not change under us mid-session.
    ///
    /// `env -0` rather than reading `$PATH` directly, because a shell variable has to be
    /// expanded by that shell's own rules — in fish `$PATH` is a list and `printf %s "$PATH"`
    /// yields only its first element. Asking `env` for the exported environment sidesteps the
    /// syntax of the shell entirely, and brings the agent's API keys along with the PATH.
    private static let loginShellEnvironment: [String: String] = {
        let configured = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let probed = probeShellEnvironment(shell: configured)
        /// A shell whose startup files failed, timed out, or rejected the flags leaves us no
        /// better off than the bare GUI environment, so fall back to a plain POSIX login shell
        /// before giving up on finding anything at all.
        if probed.isEmpty, configured != "/bin/sh" {
            return probeShellEnvironment(shell: "/bin/sh")
        }
        return probed
    }()

    private static func probeShellEnvironment(shell: String) -> [String: String] {
        guard FileManager.default.isExecutableFile(atPath: shell) else { return [:] }
        /// Startup files are free to print banners, so the environment is fenced off rather
        /// than read as the whole of stdout.
        let marker = "__KITE_ACP_ENV__"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        /// `-l` runs the login profile, and `-i` is what makes zsh read `.zshrc`, which is where
        /// most people actually add their package manager to PATH. POSIX sh and dash have no
        /// interactive mode to ask for, and passing `-i` to them fails the probe outright.
        let name = (shell as NSString).lastPathComponent.lowercased()
        let flags = (name == "sh" || name == "dash") ? ["-l", "-c"] : ["-i", "-l", "-c"]
        process.arguments = flags + ["printf %s '\(marker)'; env -0"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        /// An interactive shell that decides to read from stdin must hit EOF, not block.
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return [:]
        }
        /// A startup file can hang forever, and the agent still has to be able to launch.
        let watchdog = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3.0, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        /// Exit status is not checked: an interactive shell can report a non-zero status from
        /// something in its startup files while still having printed a perfectly good
        /// environment. Decoding is lenient because an exported value need not be valid UTF-8.
        let output = String(decoding: data, as: UTF8.self)
        guard let fenced = output.range(of: marker) else { return [:] }
        var environment: [String: String] = [:]
        for entry in output[fenced.upperBound...].components(separatedBy: "\0") {
            /// Split on the first `=` only: values legitimately contain them.
            guard let separator = entry.firstIndex(of: "="), separator != entry.startIndex else {
                continue
            }
            environment[String(entry[entry.startIndex..<separator])] = String(entry[entry.index(after: separator)...])
        }
        return environment
    }

    /// Where the agent's real binary lives, or the command that could not be found.
    enum LaunchResolution {
        case resolved(executable: String, arguments: [String])
        case missing(command: String)
    }

    /// `/usr/bin/env <agent>` reports a missing agent as an opaque exit 127, long after the
    /// process started. Do the PATH lookup here instead, so the agent launches from an absolute
    /// path and a genuinely missing one is named.
    static func resolveLaunch(executable: String, arguments: [String], searchPath: [String]) -> LaunchResolution {
        /// The Custom provider starts with nothing filled in, and `URL(fileURLWithPath:)` does
        /// not accept an empty path.
        let executable = executable.trimmingCharacters(in: .whitespaces)
        guard !executable.isEmpty else {
            return .missing(command: arguments.first ?? "")
        }
        /// `env` exists only to perform this lookup, so skip it — but not when it is carrying
        /// `NAME=value` assignments or flags, which only `env` itself knows how to apply.
        if URL(fileURLWithPath: executable).lastPathComponent == "env",
           let command = arguments.first,
           !command.contains("="),
           !command.hasPrefix("-") {
            guard let absolute = locate(command: command, in: searchPath) else {
                return .missing(command: command)
            }
            return .resolved(executable: absolute, arguments: Array(arguments.dropFirst()))
        }
        guard let absolute = locate(command: executable, in: searchPath) else {
            return .missing(command: executable)
        }
        return .resolved(executable: absolute, arguments: arguments)
    }

    private static func locate(command: String, in searchPath: [String]) -> String? {
        guard !command.isEmpty else { return nil }
        if command.contains("/") {
            let path = (command as NSString).expandingTildeInPath
            return FileManager.default.isExecutableFile(atPath: path) ? path : nil
        }
        for directory in searchPath {
            let candidate = (directory as NSString).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Tail of the agent's stderr, so a non-zero exit can say why instead of just the code.
    private var lastErrorOutput = ""
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
                    self.reportedModel = modelId
                    self.currentModelPromise.set(modelId)
                } else {
                    /// An agent rejects a model the account is not entitled to. Showing it as
                    /// current anyway would be a lie, and re-requesting it on every prompt turns
                    /// one rejection into an error on each message, so drop back to the model the
                    /// agent says it is actually running.
                    self.configuration?.model = ""
                    self.currentModelPromise.set(self.reportedModel)
                }
            }
        }
    }

    /// Recognises an agent refusing the requested model. Codex reports an entitlement failure
    /// as a raw 400 payload in its reply text rather than as an ACP error, so the response body
    /// is the only place it can be seen — which is why it used to reach the user verbatim.
    static func modelRejectionDetail(in text: String) -> String? {
        let lowered = text.lowercased()
        let refused = lowered.contains("not supported when using")
            || (lowered.contains("invalid_request_error") && lowered.contains("model"))
            || (lowered.contains("model") && lowered.contains("does not exist"))
        guard refused else { return nil }
        /// Prefer the API's own sentence over the whole JSON envelope.
        if let range = text.range(of: "\"message\"[^\"]*\"[^\"]+\"", options: .regularExpression),
           let quoted = text[range].range(of: "\"[^\"]+\"$", options: .regularExpression) {
            return String(text[range][quoted].dropFirst().dropLast())
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Drops back to whatever model the agent is actually running, so one refusal does not
    /// repeat on every subsequent message in the session.
    func fallBackToAgentDefaultModel() {
        queue.async { [weak self] in
            guard let self else { return }
            self.configuration?.model = ""
            self.currentModelPromise.set(self.reportedModel)
        }
    }

    /// The model Kite last asked the agent to use, for reporting which one was refused.
    var requestedModel: String {
        return configuration?.model ?? ""
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
            ]) { [weak self] response in
                if let error = response["error"] as? [String: Any] {
                    let message = error["message"] as? String ?? "ACP prompt failed"
                    if let detail = WorkspaceACPClient.modelRejectionDetail(in: message) {
                        let refused = self?.requestedModel ?? ""
                        self?.fallBackToAgentDefaultModel()
                        completion(.failure(WorkspaceACPClientError.modelUnavailable(model: refused, detail: detail)))
                    } else {
                        completion(.failure(WorkspaceACPClientError.remote(message)))
                    }
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
            /// Naming it matters: a profile copied from another Mac points at a home directory
            /// that does not exist here.
            statusPromise.set(.failed("Folder does not exist: \(configuration.workingDirectory)"))
            return
        }

        let searchPath = WorkspaceACPClient.agentSearchPath()
        let launch: (executable: String, arguments: [String])
        switch WorkspaceACPClient.resolveLaunch(
            executable: configuration.executable,
            arguments: configuration.arguments,
            searchPath: searchPath
        ) {
        case let .resolved(executable, arguments):
            launch = (executable, arguments)
        case let .missing(command):
            statusPromise.set(.failed(command.isEmpty
                ? "Enter the program to run under Agent Command."
                : "Could not find “\(command)”. Install it, or enter its full path under Program."))
            return
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: configuration.workingDirectory, isDirectory: true)
        process.environment = WorkspaceACPClient.agentEnvironment(searchPath: searchPath)
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.terminationHandler = { [weak self] task in
            self?.queue.async {
                guard let self, self.process === task else { return }
                let detail = self.lastErrorOutput
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: .newlines)
                    .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    .suffix(3)
                    .joined(separator: " ")
                let reason = detail.isEmpty
                    ? "Agent exited with status \(task.terminationStatus)"
                    : "Agent exited with status \(task.terminationStatus): \(detail)"
                self.stopOnQueue(status: .failed(reason))
            }
        }

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async {
                self?.consume(data)
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            // ACP reserves stdout for protocol frames; stderr is diagnostics only and must not
            // be treated as a connection failure — but keep the tail to explain a bad exit.
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.queue.async {
                self?.lastErrorOutput = String((self?.lastErrorOutput ?? "").appending(text).suffix(600))
            }
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
                        "dev.kiteapp/aiFeatures": enabledFeatures.map { feature in
                            [
                                "id": feature.rawValue,
                                "title": feature.title,
                                "access": feature.isWriteCapability ? "write" : "read"
                            ]
                        }
                    ]
                ],
                "clientInfo": [
                    "name": "kite-mac",
                    "title": "Kite for macOS",
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
            let available = WorkspaceACPClient.parseModels(from: result)
            self.modelsPromise.set(available)
            let reported = WorkspaceACPClient.parseCurrentModel(from: result)
            self.reportedModel = reported
            self.currentModelPromise.set(reported)
            self.statusPromise.set(.connected(agentName: self.agentName ?? configuration.provider.title))
            /// The model is requested over ACP rather than on the command line, because not
            /// every agent accepts a --model flag.
            let desired = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
            if !desired.isEmpty, desired != reported {
                /// A model saved from an earlier session may no longer be offered — a different
                /// agent version, or a different account. Asking for it anyway is what produced
                /// an API rejection mid-conversation, so settle it here instead.
                if available.isEmpty || available.contains(where: { $0.id == desired }) {
                    self.selectModel(desired)
                } else {
                    self.configuration?.model = ""
                }
            }
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
        lastErrorOutput = ""
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
        guard let scriptPath = Bundle.main.path(forResource: "kite_knowledge_mcp", ofType: "py") else {
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

enum WorkspaceACPClientError: LocalizedError {
    case notConnected
    case remote(String)
    /// The agent ran, but refused the model. Kept separate from `remote` so the message can
    /// say what to do about it instead of repeating a raw API payload.
    case modelUnavailable(model: String, detail: String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "ACP agent is not connected"
        case let .remote(message):
            return message
        case let .modelUnavailable(model, detail):
            let subject = model.isEmpty ? "That model" : "“\(model)”"
            return "\(subject) is not available on your account, so Kite switched back to the agent's default model. Pick a different model under Settings → Profiles & Automation.\n\nThe agent said:\n\(detail)"
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

private func workspaceActionModelId(_ action: CodexAssistantAction) -> InputDataIdentifier {
    return InputDataIdentifier("workspace.action.model.\(action.rawValue)")
}
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

    /// Models offered anywhere in this screen: what the agent reported, else the known list.
    let offeredModels = !acpModels.isEmpty
        ? acpModels
        : state.acp.provider.suggestedModels.map { WorkspaceACPModel(id: $0, name: $0) }

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

    /// Only actions that actually run through the agent can pick a model.
    let modelledActions = chatActions.filter { active.isEnabled($0) && $0.requiresAgent }
    if !modelledActions.isEmpty {
        entries.append(.sectionId(sectionId, type: .normal))
        sectionId += 1
        entries.append(.desc(sectionId: sectionId, index: index, text: .plain("MODEL PER ACTION"), data: .init(color: theme.colors.listGrayText, detectBold: true, viewType: .textTopItem)))
        index += 1
        for (position, chatAction) in modelledActions.enumerated() {
            let current = state.acp.actionModels[chatAction.rawValue] ?? ""
            var values: [ValuesSelectorValue<InputDataValue>] = [
                ValuesSelectorValue(localized: "Same as agent", value: .string(""))
            ]
            values.append(contentsOf: offeredModels.map { ValuesSelectorValue(localized: $0.name, value: .string($0.id)) })
            if !current.isEmpty, !offeredModels.contains(where: { $0.id == current }) {
                values.append(ValuesSelectorValue(localized: current, value: .string(current)))
            }
            entries.append(.selector(sectionId: sectionId, index: index, value: .string(current), error: nil, identifier: workspaceActionModelId(chatAction), placeholder: chatAction.title, viewType: bestGeneralViewType(modelledActions, for: position), values: values))
            index += 1
        }
        entries.append(.desc(sectionId: sectionId, index: index, text: .plain("Run individual actions on a different model — a cheap one for summaries, a stronger one for replies. \"Same as agent\" uses the model set above. The agent is switched to the chosen model just before the action runs."), data: .init(color: theme.colors.listGrayText, viewType: .textBottomItem)))
        index += 1
    }

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
            entries.append(.input(sectionId: sectionId, index: index, value: .string(active.localTranscription.model), error: nil, identifier: workspaceTranscriptionModelId, mode: .plain, data: .init(viewType: .innerItem), placeholder: InputDataInputPlaceholder("Model"), inputPlaceholder: "whisper-1", filter: { $0 }, limit: 256))
            index += 1
            /// A server that is not running otherwise announces itself much later, as a voice
            /// note that simply never transcribes.
            entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: InputDataIdentifier("workspace.transcription.check"), data: .init(
                name: "Check Connection",
                color: theme.colors.accent,
                type: .next,
                viewType: .lastItem,
                action: {
                    let settings = active.localTranscription
                    WorkspaceVoiceTranscriber.shared.probe(settings: settings, completion: { result in
                        switch result {
                        case let .success(message):
                            alert(for: context.window, header: "Transcription server found", info: message)
                        case let .failure(error):
                            alert(for: context.window, header: "No transcription server", info: (error.errorDescription ?? "The endpoint did not answer.") + "\n\nStart one with:\nbrew install whisper-cpp\nwhisper-server -m ~/.whisper-models/ggml-base.bin --host 127.0.0.1 --port 8080 --inference-path /v1/audio/transcriptions --convert -l auto\n\nSetup instructions: github.com/NcitDev/kite#local-voice-transcription")
                        }
                    })
                }
            )))
            index += 1
        }
        entries.append(.desc(sectionId: sectionId, index: index, text: .plain("Needs a speech-to-text server running on this Mac — Kite does not bundle one and will not download a model for you. The usual setup is Homebrew's whisper-cpp plus a model file; the full instructions are at github.com/NcitDev/kite#local-voice-transcription. Any OpenAI-compatible server works: whisper.cpp, faster-whisper-server, LocalAI, Speaches. Audio never leaves this Mac and Telegram Premium is not required. When this is off, Voice to text uses Telegram's own transcription, which needs Premium."), data: .init(color: theme.colors.listGrayText, viewType: .textBottomItem)))
        index += 1
    }


    entries.append(.sectionId(sectionId, type: .normal))
    sectionId += 1
    entries.append(.desc(sectionId: sectionId, index: index, text: .plain("KNOWLEDGE INTEGRATIONS"), data: .init(color: theme.colors.listGrayText, detectBold: true, viewType: .textTopItem)))
    index += 1
    if active.knowledgeIntegrations.isEmpty {
        entries.append(.desc(sectionId: sectionId, index: index, text: .plain("Connect local knowledge to this profile. Add a vault, provide its folder path and plain-language instructions, and Kite configures both local retrieval and agent tools."), data: .init(color: theme.colors.listGrayText, viewType: .textBottomItem)))
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
                store.selectACPProvider(provider)
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
    /// While connected the agent's own current model wins; otherwise show what will be requested.
    let effectiveModel = acpCurrentModel.isEmpty ? state.acp.model : acpCurrentModel
    var modelValues: [ValuesSelectorValue<InputDataValue>] = [
        ValuesSelectorValue(localized: "Agent default", value: .string(""))
    ]
    modelValues.append(contentsOf: offeredModels.map { ValuesSelectorValue(localized: $0.name, value: .string($0.id)) })
    /// A model the agent has since stopped listing must still be shown as the current choice.
    if !effectiveModel.isEmpty, !offeredModels.contains(where: { $0.id == effectiveModel }) {
        modelValues.append(ValuesSelectorValue(localized: effectiveModel, value: .string(effectiveModel)))
    }
    entries.append(.selector(sectionId: sectionId, index: index, value: .string(effectiveModel), error: nil, identifier: workspaceACPModelId, placeholder: "Model", viewType: .lastItem, values: modelValues))
    index += 1
    let acpHint: String
    if state.acp.provider == .custom {
        acpHint = "The program Kite starts to run this agent, the folder it treats as its project root, and the model to request. Enter the command for your own ACP agent here. The model list is read from the agent once it connects."
    } else {
        acpHint = "The program Kite starts to run \(state.acp.provider.title), the folder it treats as its project root, and the model to request. The model list is read from the agent once it connects; the rest is filled in for you."
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
        store.updateACP { configuration in
            for chatAction in CodexAssistantAction.configurable {
                guard let value = data[workspaceActionModelId(chatAction)]?.stringValue else { continue }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    configuration.actionModels.removeValue(forKey: chatAction.rawValue)
                } else {
                    configuration.actionModels[chatAction.rawValue] = trimmed
                }
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
