//
//  WorkspaceAI.swift
//  Telegram-Mac
//
//  Chat-scoped AI job coordination.
//

import Foundation
import InAppSettings
import Postbox
import SwiftSignalKit
/// How far back the in-chat Codex panel looks when "Today" is switched off.
enum WorkspaceChatRangePreset: Int, Codable, CaseIterable {
    case today = 0
    case threeDays = 2
    case sevenDays = 6
    case thirtyDays = 29

    var title: String {
        switch self {
        case .today:
            return "Today"
        case .threeDays:
            return "Last 3 days"
        case .sevenDays:
            return "Last 7 days"
        case .thirtyDays:
            return "Last 30 days"
        }
    }

    /// Days to subtract from today for the start of the range.
    var dayOffset: Int {
        return rawValue
    }
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
    let onStatus: (String) -> Void
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
            guard let self, let active = self.active else { return }
            if let status = self.statusDescription(from: event.update) {
                active.onStatus(status)
            }
            guard let text = self.textChunk(from: event.update), !text.isEmpty else {
                return
            }
            var updated = active
            updated.response += text
            self.active = updated
            active.onText(text)
        }))
    }

    @discardableResult
    func submit(
        prompt: String,
        onText: @escaping (String) -> Void,
        onStatus: @escaping (String) -> Void = { _ in },
        completion: @escaping (Result<String, Error>) -> Void
    ) -> UUID {
        let id = UUID()
        let enqueue = { [weak self] in
            guard let self else { return }
            self.queued.append(WorkspaceAIQueuedJob(id: id, prompt: prompt, onText: onText, onStatus: onStatus, completion: completion, response: ""))
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

    /// Turns an ACP session update into a short line describing what the agent is doing, so a
    /// long request reads as progress rather than a stalled spinner.
    private func statusDescription(from update: [String: Any]) -> String? {
        let kind = (update["sessionUpdate"] as? String) ?? (update["type"] as? String) ?? ""
        switch kind {
        case "agent_thought_chunk":
            return "Thinking…"
        case "agent_message_chunk":
            return "Writing…"
        case "tool_call", "tool_call_update":
            if let title = update["title"] as? String, !title.isEmpty {
                return title
            }
            return "Using a tool…"
        case "plan", "plan_update":
            return "Planning…"
        default:
            return nil
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
