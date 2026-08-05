//
//  WorkspaceAI.swift
//  Telegram-Mac
//
//  Profile-scoped AI workflow, insight, follow-up, and job coordination.
//

import Foundation
import InAppSettings
import Postbox
import SwiftSignalKit

enum WorkspaceAIWorkflowPreset: String, Codable, CaseIterable {
    case focused
    case proactive
    case scheduled
    case custom

    var title: String {
        switch self {
        case .focused:
            return "Focused"
        case .proactive:
            return "Proactive"
        case .scheduled:
            return "Scheduled"
        case .custom:
            return "Custom"
        }
    }
}

enum WorkspaceAIRollingWindow: Int, Codable, CaseIterable {
    case oneHour = 1
    case fourHours = 4
    case twelveHours = 12
    case oneDay = 24
    case threeDays = 72
    case sevenDays = 168

    var title: String {
        switch self {
        case .oneHour:
            return "Previous hour"
        case .fourHours:
            return "Previous 4 hours"
        case .twelveHours:
            return "Previous 12 hours"
        case .oneDay:
            return "Previous 24 hours"
        case .threeDays:
            return "Previous 3 days"
        case .sevenDays:
            return "Previous 7 days"
        }
    }
}

struct WorkspaceAIScheduledTrigger: Codable, Equatable {
    let id: String
    var minutesFromMidnight: Int
    var weekdays: [Int]
    var rollingWindow: WorkspaceAIRollingWindow

    init(id: String = UUID().uuidString, minutesFromMidnight: Int, weekdays: [Int], rollingWindow: WorkspaceAIRollingWindow) {
        self.id = id
        self.minutesFromMidnight = min(max(minutesFromMidnight, 0), 23 * 60 + 59)
        self.weekdays = weekdays.filter { (1 ... 7).contains($0) }
        self.rollingWindow = rollingWindow
    }
}

struct WorkspaceAIWorkflowSettings: Codable, Equatable {
    var preset: WorkspaceAIWorkflowPreset
    var generateOnOpen: Bool
    var backgroundEnabled: Bool
    var backgroundIntervalMinutes: Int
    var automaticRollingWindow: WorkspaceAIRollingWindow
    var scheduledTriggers: [WorkspaceAIScheduledTrigger]
    var maxChatsPerRun: Int
    var profileInstructions: String
    var macOSNotificationsEnabled: Bool

    static var focused: WorkspaceAIWorkflowSettings {
        return WorkspaceAIWorkflowSettings(
            preset: .focused,
            generateOnOpen: true,
            backgroundEnabled: false,
            backgroundIntervalMinutes: 30,
            automaticRollingWindow: .sevenDays,
            scheduledTriggers: [],
            maxChatsPerRun: 10,
            profileInstructions: "Prioritize direct questions, decisions, commitments, and deadlines that need my attention.",
            macOSNotificationsEnabled: false
        )
    }

    static var proactive: WorkspaceAIWorkflowSettings {
        var value = focused
        value.preset = .proactive
        value.backgroundEnabled = true
        value.backgroundIntervalMinutes = 15
        value.automaticRollingWindow = .oneDay
        value.maxChatsPerRun = 20
        return value
    }

    static var scheduled: WorkspaceAIWorkflowSettings {
        var value = focused
        value.preset = .scheduled
        value.generateOnOpen = false
        value.automaticRollingWindow = .twelveHours
        value.maxChatsPerRun = 20
        value.scheduledTriggers = [
            WorkspaceAIScheduledTrigger(minutesFromMidnight: 9 * 60, weekdays: [2, 3, 4, 5, 6], rollingWindow: .twelveHours),
            WorkspaceAIScheduledTrigger(minutesFromMidnight: 17 * 60, weekdays: [2, 3, 4, 5, 6], rollingWindow: .twelveHours)
        ]
        return value
    }

    static func preset(_ preset: WorkspaceAIWorkflowPreset) -> WorkspaceAIWorkflowSettings {
        switch preset {
        case .focused, .custom:
            var value = focused
            value.preset = preset
            return value
        case .proactive:
            return proactive
        case .scheduled:
            return scheduled
        }
    }

    mutating func normalize() {
        backgroundIntervalMinutes = [15, 30, 60].min(by: {
            abs($0 - backgroundIntervalMinutes) < abs($1 - backgroundIntervalMinutes)
        }) ?? 30
        maxChatsPerRun = [5, 10, 20, 50].min(by: {
            abs($0 - maxChatsPerRun) < abs($1 - maxChatsPerRun)
        }) ?? 10
        scheduledTriggers = Array(scheduledTriggers.prefix(4))
    }
}

enum WorkspaceAICapability: String, Codable, CaseIterable {
    case createFollowUp = "follow-up.create"
    case updateFollowUp = "follow-up.update"
    case sendMessage = "message.send"
    case scheduleMessage = "message.schedule"
    case markReviewed = "insight.mark-reviewed"

    var title: String {
        switch self {
        case .createFollowUp:
            return "Create follow-ups"
        case .updateFollowUp:
            return "Update follow-ups"
        case .sendMessage:
            return "Send messages"
        case .scheduleMessage:
            return "Schedule messages"
        case .markReviewed:
            return "Mark insights reviewed"
        }
    }
}

enum WorkspaceAIApprovalDecision: String, Codable, CaseIterable {
    case ask
    case allowAlways
    case neverAllow

    var title: String {
        switch self {
        case .ask:
            return "Ask Every Time"
        case .allowAlways:
            return "Always Allow"
        case .neverAllow:
            return "Never Allow"
        }
    }
}

struct WorkspaceAIMessageReference: Codable, Equatable, Hashable {
    let peerId: Int64
    let namespace: Int32
    let id: Int32
    let timestamp: Int32
}

enum WorkspaceAIAttentionLevel: String, Codable, CaseIterable {
    case urgent
    case action
    case review
    case low

    var rank: Int {
        switch self {
        case .urgent:
            return 3
        case .action:
            return 2
        case .review:
            return 1
        case .low:
            return 0
        }
    }
}

enum WorkspaceAISuggestionKind: String, Codable {
    case draftReply
    case createFollowUp
    case scheduleReply
    case reviewDecision
    case findRelatedNotes
}

struct WorkspaceAISuggestion: Codable, Equatable {
    let id: String
    let kind: WorkspaceAISuggestionKind
    let title: String
    let detail: String
    let proposedText: String?
    let proposedDate: Date?
}

struct WorkspaceAIInsight: Codable, Equatable {
    let id: String
    let profileId: String
    let peerId: Int64
    let rangeStart: Date
    let rangeEnd: Date
    let generatedAt: Date
    let sourceWatermark: WorkspaceAIMessageReference?
    var attentionLevel: WorkspaceAIAttentionLevel
    var reason: String
    var summary: String
    var suggestions: [WorkspaceAISuggestion]
    var sourceMessages: [WorkspaceAIMessageReference]
    var noteCitations: [String]
    var isReviewed: Bool
}

enum WorkspaceFollowUpStatus: String, Codable, CaseIterable {
    case open
    case snoozed
    case done
    case dismissed
}

struct WorkspaceFollowUp: Codable, Equatable {
    let id: String
    let profileId: String
    let peerId: Int64
    var title: String
    var notes: String
    var owner: String?
    var dueAt: Date?
    var snoozedUntil: Date?
    var status: WorkspaceFollowUpStatus
    let sourceMessages: [WorkspaceAIMessageReference]
    let createdAt: Date
    var updatedAt: Date
}

struct WorkspaceAIGenerationRecord: Codable, Equatable {
    let profileId: String
    let triggerId: String
    let completedAt: Date
    let rangeStart: Date
    let rangeEnd: Date
    let promptVersion: Int
}

struct WorkspaceAIPersistedState: Codable, Equatable {
    var schemaVersion: Int
    var insights: [WorkspaceAIInsight]
    var followUps: [WorkspaceFollowUp]
    var generationRecords: [WorkspaceAIGenerationRecord]

    static var defaultValue: WorkspaceAIPersistedState {
        return WorkspaceAIPersistedState(schemaVersion: 1, insights: [], followUps: [], generationRecords: [])
    }

    mutating func prune(now: Date = Date()) {
        let insightCutoff = now.addingTimeInterval(-30 * 24 * 60 * 60)
        insights = insights.filter { $0.generatedAt >= insightCutoff }
        let grouped = Dictionary(grouping: insights, by: { $0.profileId })
        insights = grouped.values.flatMap { values in
            values.sorted(by: { $0.generatedAt > $1.generatedAt }).prefix(50)
        }

        let followUpCutoff = now.addingTimeInterval(-30 * 24 * 60 * 60)
        followUps = followUps.filter { followUp in
            switch followUp.status {
            case .open, .snoozed:
                return true
            case .done, .dismissed:
                return followUp.updatedAt >= followUpCutoff
            }
        }
        generationRecords = Array(generationRecords.sorted(by: { $0.completedAt > $1.completedAt }).prefix(100))
    }
}

func workspaceAIState(postbox: Postbox) -> Signal<WorkspaceAIPersistedState, NoError> {
    return postbox.preferencesView(keys: [ApplicationSpecificPreferencesKeys.workspaceAIState])
    |> map { view in
        return view.values[ApplicationSpecificPreferencesKeys.workspaceAIState]?.get(WorkspaceAIPersistedState.self) ?? .defaultValue
    }
}

func updateWorkspaceAIState(
    postbox: Postbox,
    _ transform: @escaping (inout WorkspaceAIPersistedState) -> Void
) -> Signal<Void, NoError> {
    return postbox.transaction { transaction -> Void in
        var state = transaction.getPreferencesEntry(key: ApplicationSpecificPreferencesKeys.workspaceAIState)?.get(WorkspaceAIPersistedState.self) ?? .defaultValue
        transform(&state)
        state.prune()
        transaction.updatePreferencesEntry(key: ApplicationSpecificPreferencesKeys.workspaceAIState, { _ in
            return PreferencesEntry(state)
        })
    }
}

struct WorkspaceAIAnalysisSuggestion: Codable {
    let kind: WorkspaceAISuggestionKind
    let title: String
    let detail: String
    let proposedText: String?
    let proposedDate: Date?
}

struct WorkspaceAIAnalysisInsight: Codable {
    let peerId: Int64
    let attentionLevel: WorkspaceAIAttentionLevel
    let reason: String
    let summary: String
    let sourceMessageIds: [Int32]
    let suggestions: [WorkspaceAIAnalysisSuggestion]
    let noteCitations: [String]
}

struct WorkspaceAIAnalysisEnvelope: Codable {
    let insights: [WorkspaceAIAnalysisInsight]
}

enum WorkspaceAIJobError: LocalizedError {
    case cancelled
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "AI request was cancelled"
        case .emptyResponse:
            return "The AI agent returned no text"
        }
    }
}

private struct WorkspaceAIQueuedJob {
    let id: UUID
    let prompt: String
    let onText: (String) -> Void
    let completion: (Result<String, Error>) -> Void
    var response: String
}

final class WorkspaceAIJobCoordinator {
    private let client: WorkspaceACPClient
    private var queued: [WorkspaceAIQueuedJob] = []
    private var active: WorkspaceAIQueuedJob?
    private let eventsDisposable = MetaDisposable()

    init(client: WorkspaceACPClient) {
        self.client = client
        eventsDisposable.set((client.events |> deliverOnMainQueue).start(next: { [weak self] event in
            guard let self, var active = self.active, let text = self.textChunk(from: event.update), !text.isEmpty else {
                return
            }
            active.response += text
            self.active = active
            active.onText(text)
        }))
    }

    @discardableResult
    func submit(
        prompt: String,
        onText: @escaping (String) -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    ) -> UUID {
        let id = UUID()
        let enqueue = { [weak self] in
            guard let self else { return }
            self.queued.append(WorkspaceAIQueuedJob(id: id, prompt: prompt, onText: onText, completion: completion, response: ""))
            self.startNextIfNeeded()
        }
        if Thread.isMainThread {
            enqueue()
        } else {
            DispatchQueue.main.async(execute: enqueue)
        }
        return id
    }

    func cancel(_ id: UUID) {
        let cancel = { [weak self] in
            guard let self else { return }
            if let active = self.active, active.id == id {
                self.client.cancelCurrentPrompt()
                self.active = nil
                active.completion(.failure(WorkspaceAIJobError.cancelled))
                self.startNextIfNeeded()
                return
            }
            if let index = self.queued.firstIndex(where: { $0.id == id }) {
                let job = self.queued.remove(at: index)
                job.completion(.failure(WorkspaceAIJobError.cancelled))
            }
        }
        if Thread.isMainThread {
            cancel()
        } else {
            DispatchQueue.main.async(execute: cancel)
        }
    }

    private func startNextIfNeeded() {
        guard active == nil, !queued.isEmpty else { return }
        let job = queued.removeFirst()
        active = job
        client.prompt(job.prompt) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, let active = self.active, active.id == job.id else { return }
                self.active = nil
                switch result {
                case .success:
                    if active.response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        active.completion(.failure(WorkspaceAIJobError.emptyResponse))
                    } else {
                        active.completion(.success(active.response))
                    }
                case let .failure(error):
                    active.completion(.failure(error))
                }
                self.startNextIfNeeded()
            }
        }
    }

    private func textChunk(from update: [String: Any]) -> String? {
        let kind = (update["sessionUpdate"] as? String) ?? (update["type"] as? String) ?? ""
        guard kind.isEmpty || kind.contains("agent_message") || kind == "message" else {
            return nil
        }
        if let content = update["content"] as? [String: Any],
           (content["type"] as? String) == "text",
           let text = content["text"] as? String {
            return text
        }
        return update["text"] as? String
    }

    deinit {
        eventsDisposable.dispose()
    }
}

final class WorkspaceAIJobCoordinatorRegistry {
    static let shared = WorkspaceAIJobCoordinatorRegistry()

    private let lock = NSLock()
    private var coordinators: [Int64: WorkspaceAIJobCoordinator] = [:]

    func coordinator(accountId: Int64, client: WorkspaceACPClient) -> WorkspaceAIJobCoordinator {
        lock.lock()
        defer { lock.unlock() }
        if let current = coordinators[accountId] {
            return current
        }
        let coordinator = WorkspaceAIJobCoordinator(client: client)
        coordinators[accountId] = coordinator
        return coordinator
    }
}
