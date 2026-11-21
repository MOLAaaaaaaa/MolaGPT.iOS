import SwiftUI
import UIKit
import PDFKit
import UniformTypeIdentifiers

/// 图片预处理：限制长边 2048px，转 JPEG。
enum ImageProcessing {
    static func prepare(_ image: UIImage, maxSide: CGFloat = 2048, quality: CGFloat = 0.85) -> (Data, String)? {
        let size = image.size
        let scale = min(1, maxSide / max(size.width, size.height))
        let target = CGSize(width: floor(size.width * scale), height: floor(size.height * scale))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let data = rendered.jpegData(compressionQuality: quality) else { return nil }
        return (data, "image/jpeg")
    }
}

/// 文档文字抽取（P3：PDF + 纯文本/代码；Word 等在 P4）。
enum DocumentText {
    static let supportedTypes: [UTType] = [.pdf, .plainText, .text, .sourceCode, .json, .xml, .html, .commaSeparatedText,
                                           .yaml, .image, UTType("org.openxmlformats.wordprocessingml.document"),
                                           UTType(filenameExtension: "md")].compactMap { $0 }

    static func extract(data: Data, url: URL) -> String? {
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .pdf) == true || url.pathExtension.lowercased() == "pdf" {
            guard let doc = PDFDocument(data: data) else { return nil }
            return doc.string?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        if url.pathExtension.lowercased() == "docx" || (MiniZip.isZip(data) && type?.identifier.contains("wordprocessingml") == true) {
            return DocxText.extract(data) ?? "（未能从该 Word 文档中抽取到文字，可能是扫描件或格式不受支持。）"
        }
        if let s = String(data: data, encoding: .utf8) { return s.nilIfEmpty }
        // 仅在带 BOM 时按 UTF-16 解码，避免把二进制误解成乱码。
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let s = String(data: data, encoding: .utf16) {
            return s.nilIfEmpty
        }
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        if let s = String(data: data, encoding: gb), !s.contains("\u{0}") { return s.nilIfEmpty }
        return nil
    }
}

/// docx → Markdown：`word/document.xml` 的段落、标题、列表、表格（对应安卓 DocxParser）。
enum DocxText {
    static func extract(_ data: Data) -> String? {
        guard let zip = try? MiniZip(data), let e = zip.entry("word/document.xml"), let xml = try? zip.extract(e) else { return nil }
        let p = Parser()
        let parser = XMLParser(data: xml)
        parser.delegate = p
        guard parser.parse() else { return nil }
        let text = p.lines.joined(separator: "\n").replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private final class Parser: NSObject, XMLParserDelegate {
        var lines: [String] = []
        private var para = ""
        private var style: String?
        private var isList = false
        private var inText = false
        private var row: [String]?
        private var tableRows: [[String]] = []
        private var cell: String?

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            switch name {
            case "w:p": para = ""; style = nil; isList = false
            case "w:pStyle": style = attributes["w:val"]
            case "w:numPr": isList = true
            case "w:t": inText = true
            case "w:tab": para += "\t"
            case "w:br", "w:cr": para += "\n"
            case "w:tbl": tableRows = []
            case "w:tr": row = []
            case "w:tc": cell = ""
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { if inText { para += string } }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "w:t": inText = false
            case "w:p":
                if cell != nil { cell! += (cell!.isEmpty ? "" : " ") + para; return }
                var line = para
                if let st = style?.lowercased(), st.hasPrefix("heading") || st.hasPrefix("title"),
                   let level = Int(st.filter(\.isNumber)) ?? (st.hasPrefix("title") ? 1 : nil) {
                    line = String(repeating: "#", count: min(max(level, 1), 6)) + " " + line
                } else if isList { line = "- " + line }
                lines.append(line)
            case "w:tc": if let c = cell { row?.append(c.replacingOccurrences(of: "|", with: "\\|")) }; cell = nil
            case "w:tr": if let r = row { tableRows.append(r) }; row = nil
            case "w:tbl":
                guard let head = tableRows.first else { break }
                lines.append("")
                lines.append("| " + head.joined(separator: " | ") + " |")
                lines.append("|" + Array(repeating: " --- |", count: head.count).joined())
                for r in tableRows.dropFirst() { lines.append("| " + r.joined(separator: " | ") + " |") }
                lines.append("")
            default: break
            }
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// 相机拍照（UIImagePickerController 包装）。
struct CameraPicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let onImage: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let vc = UIImagePickerController()
        vc.sourceType = .camera
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ p: CameraPicker) { parent = p }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage { parent.onImage(img) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
