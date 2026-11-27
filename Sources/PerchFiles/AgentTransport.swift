import Darwin
import Foundation

struct AgentCall: Codable, Sendable {
    let tool: String
    var token: String = ""
    var query: String?
    var days: Int?
    var extensions: [String]?
    var limit: Int?
    var search_id: UUID?
    var file_ids: [UUID]?
    var file_id: UUID?
    var workflow_id: UUID?
    var request_id: UUID?
    var job_id: UUID?
}

struct AgentReply: Codable, Sendable {
    struct Item: Codable, Sendable {
        let id: UUID
        let name: String
        var path: String?
        var modified: Date?
        var url: URL?
    }

    var error: String?
    var workspace: Item?
    var files: [Item]?
    var workflows: [Item]?
    var search_id: UUID?
    var match_count: Int?
    var unreadable_directories: Int?
    var job_id: UUID?
    var status: String?
    var outputs: [Item]?
    var selected_count: Int?
    var processed_count: Int?
    var total_count: Int?
    var warnings: [String]?

    static func failure(_ message: String) -> Self { Self(error: message) }
}

enum AgentSocket {
    static var path: String {
        let identity = Bundle.main.bundleIdentifier ?? "local.perchfiles.browser"
        return NSTemporaryDirectory() + "wf-" + identity + ".sock"
    }

    static func socketAddress() throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    static func connect() throws -> FileHandle {
        var address = try socketAddress()
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw socketError() }
        let length = socklen_t(address.sun_len)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, length)
            }
        }
        guard connected == 0 else {
            let error = socketError()
            Darwin.close(descriptor)
            throw error
        }
        return channel(descriptor, timeout: 40)
    }

    static func channel(_ descriptor: Int32, timeout: Int) -> FileHandle {
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        var setting: Int32 = 1
        var interval = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &setting, socklen_t(MemoryLayout.size(ofValue: setting)))
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout.size(ofValue: interval)))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &interval, socklen_t(MemoryLayout.size(ofValue: interval)))
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    static func read(_ handle: FileHandle, limit: Int = 256 * 1024) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.recv(handle.fileDescriptor, $0.baseAddress, $0.count, 0) }
            if count < 0, errno == EINTR { continue }
            if count < 0 { throw socketError() }
            guard count > 0 else { throw POSIXError(.EPIPE) }
            let newline = buffer[..<count].firstIndex(of: 10)
            let end = newline ?? count
            guard data.count + end <= limit else { throw POSIXError(.EMSGSIZE) }
            data.append(contentsOf: buffer[..<end])
            if newline != nil { return data }
        }
    }

    static func write<T: Encodable>(_ value: T, to handle: FileHandle) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(value)
        data.append(10)
        try handle.write(contentsOf: data)
    }

    static func socketError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}

final class AgentListener {
    private let source: DispatchSourceRead

    init(receive: @escaping @MainActor (AgentCall) async -> AgentReply) throws {
        var address = try AgentSocket.socketAddress()
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw AgentSocket.socketError() }
        var bound = false
        defer {
            if !bound { Darwin.close(descriptor) }
        }
        let path = AgentSocket.path
        var existing = stat()
        if lstat(path, &existing) == 0 {
            guard existing.st_mode & S_IFMT == S_IFSOCK, existing.st_uid == getuid(),
                  (try? AgentSocket.connect()) == nil, unlink(path) == 0 else {
                throw POSIXError(.EADDRINUSE)
            }
        }
        let length = socklen_t(address.sun_len)
        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, length)
            }
        }
        guard status == 0 else { throw AgentSocket.socketError() }
        guard chmod(path, S_IRUSR | S_IWUSR) == 0, listen(descriptor, 12) == 0 else {
            let error = AgentSocket.socketError()
            unlink(path)
            throw error
        }
        bound = true
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        let queue = DispatchQueue(label: "wfolder.agent.listener")
        let slots = DispatchSemaphore(value: 8)
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setCancelHandler {
            Darwin.close(descriptor)
            unlink(path)
        }
        source.setEventHandler {
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { return }
            guard slots.wait(timeout: .now()) == .success else {
                Darwin.close(client)
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let channel = AgentSocket.channel(client, timeout: 5)
                do {
                    let request = try JSONDecoder().decode(AgentCall.self, from: AgentSocket.read(channel))
                    Task { @MainActor in
                        let reply = await receive(request)
                        DispatchQueue.global(qos: .userInitiated).async {
                            try? AgentSocket.write(reply, to: channel)
                            try? channel.close()
                            slots.signal()
                        }
                    }
                } catch {
                    try? channel.close()
                    slots.signal()
                }
            }
        }
        source.resume()
    }

    deinit { source.cancel() }
}

enum AgentMCP {
    static func run() {
        let token = ProcessInfo.processInfo.environment["WFOLDER_AGENT_TOKEN"] ?? ""
        for line in AnyIterator({ readLine() }) {
            guard line.utf8.count <= 256 * 1024,
                  let request = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String else {
                write(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Invalid JSON-RPC request"]])
                continue
            }
            guard let id = request["id"] else { continue }
            let params = request["params"] as? [String: Any] ?? [:]
            let result: [String: Any]
            switch method {
            case "initialize":
                let requested = params["protocolVersion"] as? String
                let versions = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
                result = ["protocolVersion": versions.first(where: { $0 == requested }) ?? "2025-11-25",
                          "capabilities": ["tools": [:]], "serverInfo": ["name": "wfolder", "version": "1.0"],
                          "instructions": "Search the paired workspace, present results, and submit workflows for review in wfolder."]
            case "ping": result = [:]
            case "tools/list": result = ["tools": tools]
            case "tools/call": result = call(params, token: token)
            default:
                write(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]])
                continue
            }
            write(["jsonrpc": "2.0", "id": id, "result": result])
        }
    }

    private static func call(_ params: [String: Any], token: String) -> [String: Any] {
        guard let name = params["name"] as? String, tools.contains(where: { $0["name"] as? String == name }) else {
            return toolError("Unknown wfolder tool.")
        }
        guard !token.isEmpty else { return toolError("Pair this client in wfolder's Agent Connections settings.") }
        var payload = params["arguments"] as? [String: Any] ?? [:]
        payload["tool"] = name
        payload["token"] = token
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            let call = try JSONDecoder().decode(AgentCall.self, from: data)
            let channel = try AgentSocket.connect()
            defer { try? channel.close() }
            try AgentSocket.write(call, to: channel)
            let response = try AgentSocket.read(channel)
            guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any] else {
                return toolError("wfolder returned an invalid response.")
            }
            if let error = object["error"] as? String { return toolError(error) }
            return ["structuredContent": object,
                    "content": [["type": "text", "text": String(decoding: response, as: UTF8.self)]]]
        } catch is DecodingError {
            return toolError("Invalid tool arguments. Check UUIDs, dates and file selections.")
        } catch {
            return toolError("Cannot contact wfolder. Keep it open with Agent Connections enabled and check the pairing.")
        }
    }

    private static func toolError(_ message: String) -> [String: Any] {
        ["isError": true, "content": [["type": "text", "text": message]]]
    }

    private static func write(_ value: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: value) else { return }
        data.append(10)
        try? FileHandle.standardOutput.write(contentsOf: data)
    }

    private static func tool(_ name: String, _ description: String, _ properties: [String: [String: Any]] = [:],
                             required: [String] = []) -> [String: Any] {
        ["name": name, "description": description, "inputSchema": [
            "type": "object", "properties": properties, "required": required, "additionalProperties": false
        ]]
    }

    private static var tools: [[String: Any]] {
        let uuid = ["type": "string", "format": "uuid"]
        return [
            tool("workspace", "Get the one workspace authorized for this connection."),
            tool("open_workspace", "Open the authorized workspace in wfolder."),
            tool("search", "Search authorized files by filename or topic. wfolder returns metadata and file references.",
                 ["query": ["type": "string", "maxLength": 180], "days": ["type": "integer", "minimum": 1, "maximum": 3650],
                  "extensions": ["type": "array", "items": ["type": "string"]], "limit": ["type": "integer", "minimum": 1, "maximum": 50]]),
            tool("show_search", "Open the returned results in the wfolder window.", ["search_id": uuid], required: ["search_id"]),
            tool("show_file", "Locate and preview a search result or approved workflow output in wfolder.",
                 ["file_id": uuid], required: ["file_id"]),
            tool("list_workflows", "Find saved workflows available in the authorized workspace."),
            tool("prepare_workflow", "Prepare a saved workflow for human review. Retries with the same request_id return the existing job.",
                 ["workflow_id": uuid, "request_id": uuid,
                  "file_ids": ["type": "array", "minItems": 1, "maxItems": 50, "items": uuid]],
                 required: ["workflow_id", "request_id", "file_ids"]),
            tool("show_job", "Show the proposed plan in wfolder for the user to review and edit.", ["job_id": uuid], required: ["job_id"]),
            tool("job_status", "Read real progress, results and failures. wfolder only executes after its user clicks approve.",
                 ["job_id": uuid], required: ["job_id"])
        ]
    }
}
