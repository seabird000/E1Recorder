import AppKit
import Foundation

/// Writes a note as Markdown, Word (.docx) or PDF. Word and PDF go Markdown → HTML → the system's own text engine,
/// so nothing extra has to be installed.
enum NoteExporter {
    static func fileExtension(_ format: String) -> String { ["docx", "pdf"].contains(format) ? format : "md" }

    @MainActor static func write(_ markdown: String, to url: URL) throws {
        switch url.pathExtension.lowercased() {
        case "docx":
            let a = try attributed(markdown)
            let data = try a.data(from: NSRange(location: 0, length: a.length),
                                  documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
            try data.write(to: url, options: .atomic)
        case "pdf":
            try writePDF(try attributed(markdown), to: url)
        default:
            try markdown.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    @MainActor private static func attributed(_ markdown: String) throws -> NSAttributedString {
        let html = MarkdownHTML.document(markdown)
        guard let a = NSAttributedString(html: Data(html.utf8), options: [.characterEncoding: String.Encoding.utf8.rawValue],
                                         documentAttributes: nil) else { throw AppError("纪要排版失败") }
        return a
    }

    /// A4 pages with 2 cm margins.
    @MainActor private static func writePDF(_ text: NSAttributedString, to url: URL) throws {
        let paper = NSSize(width: 595.28, height: 841.89), margin: CGFloat = 56
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: paper.width - 2 * margin, height: 10))
        view.textStorage?.setAttributedString(text)
        view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        view.sizeToFit()
        let info = NSPrintInfo(dictionary: [.jobSavingURL: url])
        info.jobDisposition = .save
        info.paperSize = paper
        info.topMargin = margin; info.bottomMargin = margin; info.leftMargin = margin; info.rightMargin = margin
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false
        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        guard op.run() else { throw AppError("生成 PDF 失败") }
    }
}

/// Just enough Markdown for our notes (and typical custom templates): front matter (dropped), headings, paragraphs,
/// lists and task lists, quotes and Obsidian callouts, tables, rules, bold, italic, inline code and links.
enum MarkdownHTML {
    static func document(_ md: String) -> String {
        """
        <html><head><meta charset="utf-8"><style>
        body { font-family: -apple-system, "PingFang SC", "Helvetica Neue", sans-serif; font-size: 12pt; line-height: 1.55; color: #1d1d1f; }
        h1 { font-size: 20pt; margin: 0 0 10pt 0; } h2 { font-size: 15pt; margin: 16pt 0 6pt 0; }
        h3 { font-size: 13pt; margin: 12pt 0 4pt 0; } h4, h5, h6 { font-size: 12pt; }
        p { margin: 0 0 8pt 0; } li { margin: 2pt 0; }
        blockquote { color: #555; border-left: 3px solid #ccc; margin: 6pt 0; padding-left: 10pt; }
        code { font-family: Menlo, monospace; font-size: 10.5pt; background: #f2f2f2; }
        table { border-collapse: collapse; margin: 6pt 0 10pt 0; } td, th { border: 1px solid #ccc; padding: 4pt 8pt; vertical-align: top; }
        th { background: #f5f5f5; } hr { border: none; border-top: 1px solid #ddd; }
        </style></head><body>
        \(body(md))
        </body></html>
        """
    }

    static func body(_ md: String) -> String {
        var lines = md.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        // drop YAML front matter
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") { lines.removeSubrange(0...end) }
        var out: [String] = []
        var para: [String] = []
        var list: String?          // "ul" / "ol"
        var i = 0
        func flushPara() { if !para.isEmpty { out.append("<p>" + para.map(inline).joined(separator: "<br>") + "</p>"); para = [] } }
        func closeList() { if let l = list { out.append("</\(l)>"); list = nil } }

        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flushPara(); closeList(); i += 1; continue }
            // headings
            if let m = line.range(of: "^#{1,6} ", options: .regularExpression) {
                flushPara(); closeList()
                let level = line[m].count - 1
                out.append("<h\(level)>\(inline(String(line[m.upperBound...])))</h\(level)>")
                i += 1; continue
            }
            // rule
            if line.range(of: "^(-{3,}|\\*{3,}|_{3,})$", options: .regularExpression) != nil { flushPara(); closeList(); out.append("<hr>"); i += 1; continue }
            // table: header row followed by a |---| row
            if line.hasPrefix("|"), i + 1 < lines.count,
               lines[i + 1].trimmingCharacters(in: .whitespaces).range(of: "^\\|?\\s*:?-{2,}", options: .regularExpression) != nil {
                flushPara(); closeList()
                var rows = [cells(line)]
                i += 2
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") { rows.append(cells(lines[i])); i += 1 }
                out.append("<table><tr>" + rows[0].map { "<th>\(inline($0))</th>" }.joined() + "</tr>"
                           + rows.dropFirst().map { "<tr>" + $0.map { "<td>\(inline($0))</td>" }.joined() + "</tr>" }.joined() + "</table>")
                continue
            }
            // quote / callout
            if line.hasPrefix(">") {
                flushPara(); closeList()
                var q: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var t = String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces)
                    if let m = t.range(of: "^\\[![a-zA-Z]+\\]\\s*", options: .regularExpression) { t.removeSubrange(m) }
                    if !t.isEmpty { q.append(inline(t)) }
                    i += 1
                }
                out.append("<blockquote>" + q.joined(separator: "<br>") + "</blockquote>")
                continue
            }
            // lists
            if let m = line.range(of: "^[-*+] ", options: .regularExpression) {
                flushPara()
                if list != "ul" { closeList(); out.append("<ul>"); list = "ul" }
                var item = String(line[m.upperBound...])
                if item.hasPrefix("[ ] ") { item = "☐ " + item.dropFirst(4) } else if item.lowercased().hasPrefix("[x] ") { item = "☑ " + item.dropFirst(4) }
                out.append("<li>\(inline(item))</li>")
                i += 1; continue
            }
            if let m = line.range(of: "^\\d+[.)] ", options: .regularExpression) {
                flushPara()
                if list != "ol" { closeList(); out.append("<ol>"); list = "ol" }
                out.append("<li>\(inline(String(line[m.upperBound...])))</li>")
                i += 1; continue
            }
            closeList()
            para.append(line)
            i += 1
        }
        flushPara(); closeList()
        return out.joined(separator: "\n")
    }

    private static func cells(_ row: String) -> [String] {
        var t = row.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Escapes HTML, then bold, italic, inline code and links (Markdown links and <url>).
    static func inline(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        func re(_ pattern: String, _ template: String) {
            t = t.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        re("`([^`]+)`", "<code>$1</code>")
        re("\\[([^\\]]+)\\]\\(&lt;([^)]+)&gt;\\)", "<a href=\"$2\">$1</a>")      // [text](<url with spaces>)
        re("\\[([^\\]]+)\\]\\(([^)\\s]+)\\)", "<a href=\"$2\">$1</a>")
        re("\\*\\*([^*]+)\\*\\*", "<b>$1</b>")
        re("(?<![*\\w])\\*([^*]+)\\*(?![*\\w])", "<i>$1</i>")
        re("==([^=]+)==", "<mark>$1</mark>")
        return t
    }
}
