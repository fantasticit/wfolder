import Foundation

struct AIChatStream {
    private struct Chunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                struct Tool: Decodable {
                    struct Function: Decodable {
                        let name: String?
                        let arguments: String?
                    }
                    let index: Int
                    let function: Function?
                }
                let content: String?
                let tool_calls: [Tool]?
            }
            let index: Int?
            let finish_reason: String?
            let delta: Delta
        }
        let choices: [Choice]
    }

    private(set) var text = ""
    private(set) var arguments: String?
    private(set) var ended = false
    private var line = Data()
    private var event = [String]()
    private var finishReason: String?
    private var toolName = ""
    private let decoder = JSONDecoder()

    var canShowText: Bool {
        let prefix = text.prefix(16).trimmingCharacters(in: .whitespacesAndNewlines)
        return !prefix.isEmpty && !prefix.hasPrefix("{") && !prefix.hasPrefix("```json")
    }

    mutating func consume(_ byte: UInt8) throws -> Bool {
        guard byte == 10 else {
            line.append(byte)
            return false
        }
        if line.last == 13 { line.removeLast() }
        defer { line.removeAll(keepingCapacity: true) }
        if !line.isEmpty {
            let value = String(decoding: line, as: UTF8.self)
            if value.hasPrefix("data:") {
                let data = value.dropFirst(5)
                event.append(String(data.first == " " ? data.dropFirst() : data))
            }
            return false
        }
        return try processEvent()
    }

    mutating func complete() throws {
        // A closed connection is only complete after the provider marks the end of the response.
        if !line.isEmpty { _ = try consume(10) }
        if !event.isEmpty { _ = try processEvent() }
        guard ended || finishReason != nil,
              finishReason.map({ ["stop", "tool_calls"].contains($0) }) ?? true else {
            throw AIServiceError.response
        }
        if arguments != nil || finishReason == "tool_calls" {
            guard toolName == "wfolder_action", arguments?.isEmpty == false else { throw AIServiceError.response }
        }
    }

    private mutating func processEvent() throws -> Bool {
        guard !event.isEmpty else { return false }
        let data = event.joined(separator: "\n")
        event.removeAll(keepingCapacity: true)
        if data == "[DONE]" {
            ended = true
            return false
        }
        guard let chunk = try? decoder.decode(Chunk.self, from: Data(data.utf8)) else { throw AIServiceError.response }
        guard let choice = chunk.choices.first(where: { $0.index == nil || $0.index == 0 }) else { return false }
        if let reason = choice.finish_reason { finishReason = reason }
        for tool in choice.delta.tool_calls ?? [] {
            guard tool.index == 0 else { throw AIServiceError.response }
            if let name = tool.function?.name { toolName += name }
            arguments = (arguments ?? "") + (tool.function?.arguments ?? "")
        }
        guard let content = choice.delta.content, !content.isEmpty else { return false }
        text += content
        return true
    }
}
