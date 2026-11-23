import CoreGraphics
import Foundation

enum NewFileFormat: String, CaseIterable, Identifiable, Sendable {
    case txt, md, rtf, pdf, docx, xlsx, pptx, csv, tsv, json, yaml, html, xml, svg

    var id: String { rawValue }

    var title: String {
        switch self {
        case .txt: "纯文本"
        case .md: "Markdown"
        case .rtf: "富文本"
        case .pdf: "PDF 文档"
        case .docx: "Word 文档"
        case .xlsx: "Excel 表格"
        case .pptx: "PowerPoint 演示文稿"
        case .csv: "CSV 表格"
        case .tsv: "TSV 表格"
        case .json: "JSON"
        case .yaml: "YAML"
        case .html: "HTML 网页"
        case .xml: "XML"
        case .svg: "SVG 图形"
        }
    }

    var label: String { "\(title) (.\(rawValue))" }

    static let groups: [(title: String, formats: [Self])] = [
        ("文档", [.txt, .md, .rtf, .pdf, .docx]),
        ("表格与演示", [.xlsx, .csv, .tsv, .pptx]),
        ("网页与数据", [.json, .yaml, .html, .xml, .svg])
    ]

    func contents(templates: URL?) throws -> Data {
        switch self {
        case .pdf:
            let bytes = NSMutableData()
            var page = CGRect(x: 0, y: 0, width: 595, height: 842)
            guard let consumer = CGDataConsumer(data: bytes),
                  let document = CGContext(consumer: consumer, mediaBox: &page, nil) else {
                throw FileActionError.templateUnavailable
            }
            document.beginPDFPage(nil)
            document.endPDFPage()
            document.closePDF()
            return bytes as Data
        case .docx, .xlsx, .pptx:
            guard let template = templates?.appendingPathComponent("Blank.\(rawValue)"),
                  let bytes = try? Data(contentsOf: template) else {
                throw FileActionError.templateUnavailable
            }
            return bytes
        default:
            return Data(starterText.utf8)
        }
    }

    private var starterText: String {
        switch self {
        case .txt: ""
        case .md: "# 标题\n\n"
        case .rtf: #"{\rtf1\ansi\deff0{\fonttbl{\f0 Helvetica;}}\f0\fs24\par}"# + "\n"
        case .csv: "列 1,列 2\r\n"
        case .tsv: "列 1\t列 2\n"
        case .json: "{\n}\n"
        case .yaml: "{}\n"
        case .html:
            """
            <!doctype html>
            <html lang="zh-CN">
            <head>
              <meta charset="utf-8">
              <title>未命名网页</title>
            </head>
            <body>
            </body>
            </html>

            """
        case .xml: "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<root />\n"
        case .svg: "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"800\" height=\"600\" viewBox=\"0 0 800 600\"></svg>\n"
        default: ""
        }
    }
}
