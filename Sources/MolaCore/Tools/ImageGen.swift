import Foundation

// 图像生成（对应安卓 ByokImageApi：OPENAI_IMAGES、OPENAI_CHAT_IMAGE、Gemini generateContent）。
// 请求构造 + 响应解析；发送与落盘由 App 层负责。

public struct ImageGenConfig: Codable, Sendable, Hashable {
    public var imageSize: String = "1K"
    public var aspectRatio: String = "1:1"
    public var reasoning: Bool = false
    public var reasoningEffort: String = "medium"

    public static let sizes = ["0.5K", "1K", "2K", "4K"]
    public static let aspectRatios = ["1:1", "16:9", "9:16", "4:3", "3:4"]
    public static let efforts = ["low", "medium", "high", "xhigh", "max"]

    public init() {}

    /// Images API 的 `size`（宽x高）。
    public var pixelSize: String {
        let base: Int = switch imageSize { case "0.5K": 512; case "2K": 2048; case "4K": 3840; default: 1024 }
        let parts = aspectRatio.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return "\(base)x\(base)" }
        if parts[0] == parts[1] { return "\(base)x\(base)" }
        let long = Double(base), ratio = parts[0] / parts[1]
        let w = ratio > 1 ? long : long * ratio, h = ratio > 1 ? long / ratio : long
        func r16(_ v: Double) -> Int { max(256, Int((v / 16).rounded()) * 16) }
        return "\(r16(w))x\(r16(h))"
    }
}

/// 工作台的额外参数（gpt-image 系列）。
public struct ImageParams: Codable, Sendable, Hashable {
    public var quality = "auto"
    public var outputFormat = "png"
    public var background = "auto"
    public var moderation = "auto"
    public var compression = 80
    public var timeoutSeconds = 600
    public init() {}
}

public enum ImageGenAPI {
    static func isGptImage(_ model: String) -> Bool { model.lowercased().contains("gpt-image") }
    static func isGemini25(_ model: String) -> Bool { model.lowercased().contains("gemini-2.5") }

    static func headers(_ provider: ByokProvider) -> [String: String] {
        var h = ProviderHeaders.build(provider, stream: false)
        h["User-Agent"] = MolaUA.fixed
        return h
    }

    /// 生成请求。`size` 为空时按配置推算。
    public static func generate(provider: ByokProvider, model: String, prompt: String, config: ImageGenConfig,
                                params: ImageParams = ImageParams(), count: Int = 1, size: String? = nil) throws -> HTTPRequestSpec {
        if provider.type == .gemini {
            if model.lowercased().hasPrefix("imagen-") { throw ProviderError.decoding("Imagen 已停止服务，请选择 Gemini 图像模型") }
            var cfg: [String: JSONValue] = ["aspectRatio": .string(config.aspectRatio)]
            if !isGemini25(model) { cfg["imageSize"] = .string(config.imageSize) }
            let body: JSONValue = ["contents": [["role": "user", "parts": [["text": .string(prompt)]]]],
                                   "generationConfig": ["responseModalities": ["IMAGE", "TEXT"], "imageConfig": .object(cfg)]]
            var p = provider
            if provider.purpose == .image, !provider.imagePath.contains("images/generations") { p.chatPath = provider.imagePath }
            var spec = HTTPRequestSpec(url: try ProviderAdapters.url(GeminiAdapter.endpoint(p, model: model, stream: false)),
                                       headers: headers(provider), body: body.data())
            spec.timeout = TimeInterval(params.timeoutSeconds)
            return spec
        }
        switch provider.imageFormatFor(model) {
        case .openAIImages:
            var body: [String: JSONValue] = ["model": .string(model), "prompt": .string(prompt), "n": .number(Double(count)),
                                             "size": .string(size?.nonBlank ?? config.pixelSize)]
            if isGptImage(model) {
                if params.quality != "auto" { body["quality"] = .string(params.quality) }
                if params.background != "auto" { body["background"] = .string(params.background) }
                if params.outputFormat != "png" {
                    body["output_format"] = .string(params.outputFormat)
                    if params.outputFormat != "png" { body["output_compression"] = .number(Double(params.compression)) }
                }
                if params.moderation != "auto" { body["moderation"] = .string(params.moderation) }
            } else if provider.isOpenRouter || provider.host.contains("x.ai") {
                body["aspect_ratio"] = .string(config.aspectRatio)
                body["size"] = nil
            } else {
                body["response_format"] = "b64_json"
            }
            if let m = provider.model(model) { applyCustom(&body, m.customBody) }
            var spec = HTTPRequestSpec(url: try ProviderAdapters.url(provider.endpoint(provider.imagePath)),
                                       headers: headers(provider), body: JSONValue.object(body).data())
            spec.timeout = TimeInterval(params.timeoutSeconds)
            return spec
        case .openAIChatImage:
            let cfg: JSONValue = isGemini25(model) ? ["aspect_ratio": .string(config.aspectRatio)]
                : ["image_size": .string(config.imageSize), "aspect_ratio": .string(config.aspectRatio)]
            var body: [String: JSONValue] = ["model": .string(model), "stream": false, "modalities": ["image", "text"],
                                             "image_config": cfg,
                                             "messages": [["role": "user", "content": .string("\(prompt)（尺寸 \(config.imageSize)）")]]]
            if !provider.isOpenRouter { body["extra_body"] = ["google": ["image_config": cfg]] }
            if provider.isOpenRouter, config.reasoning {
                body["reasoning"] = ["effort": .string(config.reasoningEffort), "exclude": true]
            }
            if let m = provider.model(model) { applyCustom(&body, m.customBody) }
            var spec = HTTPRequestSpec(url: try ProviderAdapters.url(provider.endpoint(provider.chatPath)),
                                       headers: headers(provider), body: JSONValue.object(body).data())
            spec.timeout = TimeInterval(params.timeoutSeconds)
            return spec
        }
    }

    /// 图像编辑（参考图 / 蒙版）：OpenAI Images edits，multipart。
    public static func edit(provider: ByokProvider, model: String, prompt: String, size: String, images: [(Data, String)],
                            mask: Data?, params: ImageParams = ImageParams()) throws -> HTTPRequestSpec {
        let boundary = "mola-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        func file(_ name: String, _ data: Data, _ filename: String, _ mime: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
            body.append(data); body.append(Data("\r\n".utf8))
        }
        field("model", model); field("prompt", prompt); field("size", size)
        if isGptImage(model) {
            if params.quality != "auto" { field("quality", params.quality) }
            if params.background != "auto" { field("background", params.background) }
            if params.outputFormat != "png" { field("output_format", params.outputFormat) }
        } else {
            field("response_format", "b64_json")
        }
        for (i, (data, mime)) in images.enumerated() {
            file(images.count > 1 ? "image[]" : "image", data, "image\(i).\(mime.contains("jpeg") ? "jpg" : "png")", mime)
        }
        if let mask { file("mask", mask, "mask.png", "image/png") }
        body.append(Data("--\(boundary)--\r\n".utf8))
        var h = headers(provider)
        h["Content-Type"] = "multipart/form-data; boundary=\(boundary)"
        var spec = HTTPRequestSpec(url: try ProviderAdapters.url(provider.endpoint(provider.imageEditPath)), headers: h, body: body)
        spec.timeout = TimeInterval(params.timeoutSeconds)
        return spec
    }

    static func applyCustom(_ body: inout [String: JSONValue], _ params: [CustomBodyParam]) {
        let protected: Set<String> = ["model", "prompt", "messages", "contents", "stream", "image", "mask"]
        for p in params where !protected.contains(p.key) {
            if let v = JSONValue.parse(p.value) { body[p.key] = v } else { body[p.key] = .string(p.value) }
        }
    }

    /// 从响应里提取全部图片（data URI 或 http URL），去重保序；没有图时返回 text 供报错。
    public static func extractImages(_ data: Data) -> (images: [String], text: String?) {
        guard let root = JSONValue.parse(data) else {
            return (scanText(String(decoding: data, as: UTF8.self)), nil)
        }
        if let e = root["error"], !e.isNull { return ([], e["message"]?.stringValue ?? e.stringValue ?? "图像服务返回错误") }
        var found: [String] = []
        var texts: [String] = []
        // OpenAI Images：data[].b64_json / url
        for d in root["data"]?.arrayValue ?? [] {
            if let b = d["b64_json"]?.stringValue { found.append("data:image/png;base64,\(b)") }
            else if let u = d["url"]?.stringValue { found.append(u) }
        }
        // OpenRouter：choices[0].message.images[]
        for img in root["choices"]?[0]?["message"]?["images"]?.arrayValue ?? [] {
            if let u = img["image_url"]?["url"]?.stringValue ?? img["image_url"]?.stringValue ?? img["url"]?.stringValue { found.append(u) }
        }
        // Gemini：candidates[0].content.parts[].inlineData
        for p in root["candidates"]?[0]?["content"]?["parts"]?.arrayValue ?? [] {
            let inline = p["inlineData"] ?? p["inline_data"]
            if let d = inline?["data"]?.stringValue {
                found.append("data:\(inline?["mimeType"]?.stringValue ?? inline?["mime_type"]?.stringValue ?? "image/png");base64,\(d)")
            } else if let t = p["text"]?.stringValue { texts.append(t) }
        }
        if found.isEmpty { walk(root, &found, &texts) }
        if found.isEmpty { for t in texts { found += scanText(t) } }
        var seen = Set<String>()
        let unique = found.filter { seen.insert($0).inserted }
        return (unique, texts.joined(separator: "\n").nonBlank)
    }

    private static func walk(_ v: JSONValue, _ found: inout [String], _ texts: inout [String]) {
        switch v {
        case .object(let o):
            for (k, val) in o {
                if ["url", "image_url", "image", "src"].contains(k), let s = val.stringValue, looksImage(s) { found.append(normalize(s)) }
                else if k == "b64_json", let s = val.stringValue { found.append("data:image/png;base64,\(s)") }
                else if ["text", "content"].contains(k), let s = val.stringValue { texts.append(s) }
                else { walk(val, &found, &texts) }
            }
        case .array(let a): a.forEach { walk($0, &found, &texts) }
        default: break
        }
    }

    static func looksImage(_ s: String) -> Bool {
        s.hasPrefix("data:image/") || s.hasPrefix("http://") || s.hasPrefix("https://")
    }
    static func normalize(_ s: String) -> String { s }

    static func scanText(_ t: String) -> [String] {
        var out: [String] = []
        let patterns = [#"data:image/[a-zA-Z+]+;base64,[A-Za-z0-9+/=]+"#,
                        #"!\[[^\]]*\]\((https?://[^)\s]+)\)"#,
                        #"<img[^>]+src=["'](https?://[^"']+)["']"#,
                        #"https?://[^\s)"'<>]+\.(?:png|jpe?g|webp|gif)(?:\?[^\s)"'<>]*)?"#]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) else { continue }
            let ns = t as NSString
            for m in re.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
                let r = m.numberOfRanges > 1 && m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range
                out.append(ns.substring(with: r))
            }
            if !out.isEmpty { return out }
        }
        if let r = t.range(of: #"[A-Za-z0-9+/=]{200,}"#, options: .regularExpression) {
            out.append("data:image/png;base64,\(t[r])")
        }
        return out
    }

    /// data URI → (字节, 扩展名)。
    public static func decodeDataURI(_ s: String) -> (Data, String)? {
        guard s.hasPrefix("data:"), let comma = s.firstIndex(of: ",") else { return nil }
        let meta = s[s.index(s.startIndex, offsetBy: 5)..<comma]
        guard let data = Data(base64Encoded: String(s[s.index(after: comma)...]), options: .ignoreUnknownCharacters) else { return nil }
        let ext = meta.contains("jpeg") || meta.contains("jpg") ? "jpg" : meta.contains("webp") ? "webp" : meta.contains("gif") ? "gif" : "png"
        return (data, ext)
    }
}

public enum VisionProxy {
    /// view_image：用视觉模型非流式回答一个关于图片的问题（四家协议复用 ChatRequest）。
    public static func request(provider: ByokProvider, model: ProviderModel, query: String, image: WireMessage.Part) throws -> HTTPRequestSpec {
        let req = ChatRequest(provider: provider, model: model, messages: [WireMessage(role: .user, parts: [.text(query), image])],
                              maxTokens: 2048, stream: false)
        var spec = try ProviderAdapters.buildRequest(req)
        spec.timeout = 120
        return spec
    }
}
