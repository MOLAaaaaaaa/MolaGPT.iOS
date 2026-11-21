import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// BYOK 聊天客户端：把请求发出去，把 SSE 流解码为 StreamEvent。
public final class ChatClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    /// 非流式请求，返回 (状态码, 响应体)。
    public func send(_ spec: HTTPRequestSpec) async throws -> (Int, Data) {
        let (data, resp) = try await session.data(for: spec.urlRequest)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    public func fetchModels(_ provider: ByokProvider) async throws -> [ProviderModel] {
        let (status, data) = try await send(try ModelListAPI.buildRequest(provider))
        guard (200..<300).contains(status) else {
            throw ProviderError.http(status: status, body: String(decoding: data, as: UTF8.self))
        }
        return try ModelListAPI.parse(provider.type, baseUrl: provider.baseUrl, body: data)
    }

    /// 生成标题；任何失败返回 nil（调用方回退）。
    public func generateTitle(provider: ByokProvider, model: ProviderModel, messages: [(role: Role, text: String)]) async -> String? {
        guard let spec = try? Titler.buildRequest(provider: provider, model: model, messages: messages),
              let (status, data) = try? await send(spec), (200..<300).contains(status) else { return nil }
        return Titler.clean(ProviderAdapters.parseNonStreamText(provider.type, body: data))
    }

    /// 非流式补全（记忆整理、上下文压缩等后台任务用）。失败抛错。
    public func complete(provider: ByokProvider, model: ProviderModel, system: String?, user: String, maxTokens: Int,
                         timeout: TimeInterval = 300) async throws -> (text: String, usage: Usage?) {
        var req = ChatRequest(provider: provider, model: model, system: system, messages: [.text(.user, user)],
                              temperature: nil, useThinking: false, maxTokens: maxTokens, stream: false)
        req.useThinking = false
        var spec = try ProviderAdapters.buildRequest(req)
        spec.timeout = timeout
        let (status, data) = try await send(spec)
        guard (200..<300).contains(status) else {
            throw ProviderError.http(status: status, body: String(decoding: data, as: UTF8.self))
        }
        guard let text = ProviderAdapters.parseNonStreamText(provider.type, body: data) else {
            throw ProviderError.decoding(ProviderError.summarize(String(decoding: data, as: UTF8.self)))
        }
        return (text, ProviderAdapters.parseNonStreamUsage(provider.type, body: data))
    }

    /// 测试连接：发一条极短的非流式消息。
    public func testConnection(provider: ByokProvider, model: ProviderModel) async -> Result<String, Error> {
        do {
            let req = ChatRequest(provider: provider, model: model, messages: [.text(.user, "ping")],
                                  temperature: nil, useThinking: false, maxTokens: 16, stream: false)
            let (status, data) = try await send(try ProviderAdapters.buildRequest(req))
            guard (200..<300).contains(status) else {
                throw ProviderError.http(status: status, body: String(decoding: data, as: UTF8.self))
            }
            return .success(ProviderAdapters.parseNonStreamText(provider.type, body: data) ?? "")
        } catch {
            return .failure(error)
        }
    }

    #if canImport(Darwin)
    /// 流式聊天（含多轮工具调用）。取消 Task 即中断连接。
    public func stream(_ request: ChatRequest, executor: (any ToolExecutor)? = nil, maxToolRounds: Int = 16) -> AsyncThrowingStream<StreamEvent, Error> {
        ToolLoop.run(request, executor: executor, maxRounds: maxToolRounds, transport: { [session] spec in
            try await Self.lines(session: session, spec: spec)
        })
    }

    /// 发出请求，返回逐行响应；HTTP 非 2xx 时读出错误体并抛出。
    public static func lines(session: URLSession, spec: HTTPRequestSpec) async throws -> AsyncThrowingStream<String, Error> {
        let (bytes, resp) = try await session.bytes(for: spec.urlRequest)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if !(200..<300).contains(status) {
            var body = Data()
            for try await b in bytes {
                body.append(b)
                if body.count > 64_000 { break }
            }
            throw ProviderError.http(status: status, body: String(decoding: body, as: UTF8.self))
        }
        return bytes.linesPreservingEmpty
    }
    #endif
}

#if canImport(Darwin)
extension URLSession.AsyncBytes {
    /// 与 `.lines` 不同：保留空行（SSE 以空行分隔事件），并兼容 `\r\n`。
    var linesPreservingEmpty: AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var buffer = [UInt8]()
                buffer.reserveCapacity(4096)
                do {
                    for try await byte in self {
                        if byte == 0x0A {
                            if buffer.last == 0x0D { buffer.removeLast() }
                            continuation.yield(String(decoding: buffer, as: UTF8.self))
                            buffer.removeAll(keepingCapacity: true)
                        } else {
                            buffer.append(byte)
                        }
                    }
                    if !buffer.isEmpty { continuation.yield(String(decoding: buffer, as: UTF8.self)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
