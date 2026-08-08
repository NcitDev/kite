//
//  WorkspaceVoiceTranscriber.swift
//  Telegram-Mac
//
//  Sends voice messages to a locally running speech-to-text server.
//

import Foundation
import Postbox
import SwiftSignalKit
import TelegramCore

/// Points at any OpenAI-compatible transcription server running on this machine —
/// whisper.cpp's server, faster-whisper-server, LocalAI, and Speaches all expose the
/// same multipart endpoint and all answer with `{"text": "…"}`.
struct WorkspaceLocalTranscription: Codable, Equatable {
    var isEnabled: Bool
    var endpoint: String
    var model: String

    static var defaultValue: WorkspaceLocalTranscription {
        return WorkspaceLocalTranscription(
            isEnabled: false,
            endpoint: "http://127.0.0.1:8080/v1/audio/transcriptions",
            model: "whisper-1"
        )
    }

    var resolvedURL: URL? {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.host != nil else {
            return nil
        }
        return url
    }
}

enum WorkspaceTranscriptionError: LocalizedError {
    case notConfigured
    case unreachable(String)
    case badResponse(Int)
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Local transcription endpoint is not a valid URL."
        case let .unreachable(reason):
            return "Could not reach the local transcription server: \(reason)"
        case let .badResponse(code):
            return "The local transcription server returned HTTP \(code)."
        case .emptyResult:
            return "The local transcription server returned no text."
        }
    }
}

final class WorkspaceVoiceTranscriber {
    static let shared = WorkspaceVoiceTranscriber()

    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        /// Local models can be slow on first load, but a stuck request must not hang the panel.
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: configuration)
    }

    /// Downloads the voice note if needed, then posts it to the configured server.
    func transcribe(
        message: Message,
        file: TelegramMediaFile,
        account: Account,
        settings: WorkspaceLocalTranscription
    ) -> Signal<String, WorkspaceTranscriptionError> {
        guard let url = settings.resolvedURL else {
            return .fail(.notConfigured)
        }

        let reference = FileMediaReference.message(message: MessageReference(message), media: file)
        let fetch = chatMessageFileInteractiveFetched(account: account, fileReference: reference)
        let data = account.postbox.mediaBox.resourceData(file.resource)
        |> filter { $0.complete }
        |> take(1)

        return Signal { subscriber in
            let fetchDisposable = fetch.start()
            let dataDisposable = data.start(next: { [weak self] resourceData in
                guard let self else { return }
                guard let payload = try? Data(contentsOf: URL(fileURLWithPath: resourceData.path)), !payload.isEmpty else {
                    subscriber.putError(.emptyResult)
                    return
                }
                self.post(payload: payload, fileName: file.fileName ?? "voice.ogg", to: url, settings: settings, completion: { result in
                    switch result {
                    case let .success(text):
                        subscriber.putNext(text)
                        subscriber.putCompletion()
                    case let .failure(error):
                        subscriber.putError(error)
                    }
                })
            })
            return ActionDisposable {
                fetchDisposable.dispose()
                dataDisposable.dispose()
            }
        }
    }

    private func post(
        payload: Data,
        fileName: String,
        to url: URL,
        settings: WorkspaceLocalTranscription,
        completion: @escaping (Result<String, WorkspaceTranscriptionError>) -> Void
    ) {
        let boundary = "telegramwork-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(payload)
        body.append("\r\n".data(using: .utf8)!)

        let model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.isEmpty {
            appendField("model", model)
        }
        appendField("response_format", "json")
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(.unreachable(error.localizedDescription)))
                return
            }
            if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                completion(.failure(.badResponse(http.statusCode)))
                return
            }
            guard let data else {
                completion(.failure(.emptyResult))
                return
            }
            /// `{"text": "…"}` is what every compatible server returns; plain text is a fallback.
            var text: String?
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                text = object["text"] as? String
            }
            if text == nil {
                text = String(data: data, encoding: .utf8)
            }
            /// whisper.cpp emits a newline per decoded segment, which breaks a single sentence
            /// across lines. Collapse all runs of whitespace back into single spaces.
            let normalized = (text ?? "")
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if normalized.isEmpty {
                completion(.failure(.emptyResult))
            } else {
                completion(.success(normalized))
            }
        }.resume()
    }
}
