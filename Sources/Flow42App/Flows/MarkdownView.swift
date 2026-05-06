// MarkdownView.swift - Render the Markdown produced by
// `FlowMarkdownRenderer.render(flowDir:)` as SwiftUI views.
//
// The renderer's output is well-formed and predictable (we own the
// generator), so we don't need a full CommonMark parser — a small
// line-driven walker handles every block type the renderer can emit:
//
//   - ATX headings:    # / ## / ### (h1..h3 styled differently)
//   - Blockquotes:     >   prose
//   - Image:           ![alt](path)            ← path is flow-dir-relative
//   - Code fence:      ```lang … ```           ← rendered as monospaced block
//   - Details/summary: <details>...</details>  ← collapsed disclosure
//   - Tables:          GitHub pipe tables
//   - Bold / italic / inline code via AttributedString(markdown:)
//
// Image paths are resolved relative to `flowDir` (the renderer emits
// `steps/NNNN-action/screenshot.jpg`). Absolute file URLs are passed
// through unchanged.

import AppKit
import SwiftUI

struct MarkdownView: View {
    /// The Markdown string from FlowMarkdownRenderer.render(...).
    let markdown: String
    /// Base directory for resolving relative image paths.
    let baseDir: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    // MARK: - Block tree

    private enum Block {
        case heading(level: Int, text: String)
        case paragraph(String)
        case blockquote([String])
        case image(alt: String, path: String)
        case codeBlock(language: String?, content: String)
        case details(summary: String, body: [Block])
        case table(headers: [String], rows: [[String]])
    }

    private var blocks: [Block] {
        Self.parse(markdown)
    }

    // MARK: - Block view dispatch

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            headingView(level: level, text: text)
        case .paragraph(let text):
            paragraphView(text)
        case .blockquote(let lines):
            blockquoteView(lines)
        case .image(let alt, let path):
            imageView(alt: alt, path: path)
        case .codeBlock(let language, let content):
            codeBlockView(language: language, content: content)
        case .details(let summary, let inner):
            detailsView(summary: summary, body: inner)
        case .table(let headers, let rows):
            tableView(headers: headers, rows: rows)
        }
    }

    // MARK: - Block renderers

    @ViewBuilder
    private func headingView(level: Int, text: String) -> some View {
        let inline = inlineAttributed(text)
        switch level {
        case 1: Text(inline).font(.system(size: 30, weight: .bold)).padding(.top, 4)
        case 2: Text(inline).font(.system(size: 22, weight: .semibold)).padding(.top, 8)
        default: Text(inline).font(.system(size: 17, weight: .semibold)).padding(.top, 6)
        }
    }

    private func paragraphView(_ text: String) -> some View {
        Text(inlineAttributed(text))
            .font(.system(size: 14))
            .foregroundStyle(.primary)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func blockquoteView(_ lines: [String]) -> some View {
        // Stitch the lines back into a single paragraph, italicized, with
        // a left accent bar. Matches the Pause-callout style in PlayPanel.
        let joined = lines.joined(separator: "\n")
        return HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(.tint)
                .frame(width: 3)
                .frame(maxHeight: .infinity)
            Text(inlineAttributed(joined))
                .font(.system(size: 14))
                .italic()
                .foregroundStyle(.primary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func imageView(alt: String, path: String) -> some View {
        let abs = resolveImagePath(path)
        if let img = NSImage(contentsOfFile: abs) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.white.opacity(0.06), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 2)
                .accessibilityLabel(alt)
        } else {
            placeholderImage(alt: alt)
        }
    }

    private func placeholderImage(alt: String) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(.primary.opacity(0.04))
            .frame(height: 140)
            .overlay(
                VStack(spacing: 4) {
                    Image(systemName: "photo")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(alt.isEmpty ? "(missing screenshot)" : alt)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            )
    }

    private func codeBlockView(language: String?, content: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let lang = language, !lang.isEmpty {
                Text(lang.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(content)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                    .padding(12)
                    .textSelection(.enabled)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.primary.opacity(0.05))
        )
    }

    /// AnyView-erased so the opaque return type doesn't recurse on
    /// blockView → detailsView → blockView.
    private func detailsView(summary: String, body: [Block]) -> AnyView {
        AnyView(
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(body.enumerated()), id: \.offset) { _, b in
                        blockView(b)
                    }
                }
                .padding(.top, 8)
            } label: {
                Text(summary)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        )
    }

    private func tableView(headers: [String], rows: [[String]]) -> some View {
        // Simple grid layout. Tables in flow.yaml's renderer are small
        // (params lists), so we don't need anything fancy.
        VStack(alignment: .leading, spacing: 0) {
            tableRow(cells: headers, isHeader: true)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                Divider().opacity(0.3)
                tableRow(cells: row, isHeader: false)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.primary.opacity(0.04))
        )
    }

    private func tableRow(cells: [String], isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                Text(inlineAttributed(cell))
                    .font(.system(size: 12, weight: isHeader ? .semibold : .regular))
                    .foregroundStyle(isHeader ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }

    // MARK: - Inline → AttributedString

    /// Use Apple's CommonMark inline parsing for **bold**, _italic_,
    /// `code`. Stripping table pipes is unnecessary; we route table cells
    /// through here too.
    private func inlineAttributed(_ s: String) -> AttributedString {
        if let attr = try? AttributedString(markdown: s, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )) {
            return attr
        }
        return AttributedString(s)
    }

    // MARK: - Image path resolution

    private func resolveImagePath(_ raw: String) -> String {
        if raw.hasPrefix("/") { return raw }
        return (baseDir as NSString).appendingPathComponent(raw)
    }

    // MARK: - Parser

    /// Line-oriented Markdown walker. Not a full CommonMark implementation
    /// — only handles the block types FlowMarkdownRenderer can emit. Fast,
    /// dependency-free, predictable.
    private static func parse(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        let lines = markdown.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]

            // Skip blank lines.
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                i += 1; continue
            }

            // Heading.
            if line.hasPrefix("# ") {
                blocks.append(.heading(level: 1, text: String(line.dropFirst(2))))
                i += 1; continue
            }
            if line.hasPrefix("## ") {
                blocks.append(.heading(level: 2, text: String(line.dropFirst(3))))
                i += 1; continue
            }
            if line.hasPrefix("### ") {
                blocks.append(.heading(level: 3, text: String(line.dropFirst(4))))
                i += 1; continue
            }

            // Image (single line — `![alt](path)`).
            if let img = parseImageLine(line) {
                blocks.append(.image(alt: img.alt, path: img.path))
                i += 1; continue
            }

            // Blockquote — collect consecutive `>`-prefixed lines.
            if line.hasPrefix(">") {
                var quoted: [String] = []
                while i < lines.count, lines[i].hasPrefix(">") {
                    let stripped = lines[i].dropFirst().trimmingCharacters(in: .whitespaces)
                    quoted.append(String(stripped))
                    i += 1
                }
                blocks.append(.blockquote(quoted))
                continue
            }

            // Code fence — ``` ... ```
            if line.hasPrefix("```") {
                let lang = String(line.dropFirst(3))
                    .trimmingCharacters(in: .whitespaces)
                i += 1
                var content: [String] = []
                while i < lines.count, !lines[i].hasPrefix("```") {
                    content.append(lines[i])
                    i += 1
                }
                if i < lines.count { i += 1 } // consume closing fence
                blocks.append(.codeBlock(
                    language: lang.isEmpty ? nil : lang,
                    content: content.joined(separator: "\n")
                ))
                continue
            }

            // Details disclosure.
            if line.hasPrefix("<details>") {
                // Pull the summary (next line `<summary>...</summary>`),
                // then body until `</details>`.
                var summary = ""
                if line.contains("<summary>") {
                    summary = extractSummary(line)
                }
                i += 1
                if summary.isEmpty, i < lines.count, lines[i].contains("<summary>") {
                    summary = extractSummary(lines[i])
                    i += 1
                }
                var inner: [String] = []
                while i < lines.count, !lines[i].contains("</details>") {
                    inner.append(lines[i])
                    i += 1
                }
                if i < lines.count { i += 1 } // consume </details>
                let innerBlocks = parse(inner.joined(separator: "\n"))
                blocks.append(.details(summary: summary, body: innerBlocks))
                continue
            }

            // Pipe table — header line, separator, then rows.
            if line.contains("|"), i + 1 < lines.count,
               lines[i + 1].contains("---") {
                let headers = splitPipeRow(line)
                i += 2 // skip separator
                var rows: [[String]] = []
                while i < lines.count, lines[i].contains("|"),
                      !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(splitPipeRow(lines[i]))
                    i += 1
                }
                blocks.append(.table(headers: headers, rows: rows))
                continue
            }

            // Paragraph — collect lines until a blank line or a
            // structural marker.
            var paragraphLines: [String] = [line]
            i += 1
            while i < lines.count {
                let next = lines[i]
                if next.trimmingCharacters(in: .whitespaces).isEmpty { break }
                if next.hasPrefix("#") { break }
                if next.hasPrefix(">") { break }
                if next.hasPrefix("```") { break }
                if next.hasPrefix("<details>") { break }
                if next.hasPrefix("![") { break }
                paragraphLines.append(next)
                i += 1
            }
            blocks.append(.paragraph(paragraphLines.joined(separator: " ")))
        }
        return blocks
    }

    private static func parseImageLine(_ line: String) -> (alt: String, path: String)? {
        // ![alt](path)
        guard line.hasPrefix("!["), let altEnd = line.firstIndex(of: "]"),
              let pathStart = line.firstIndex(of: "("),
              let pathEnd = line.lastIndex(of: ")"),
              pathStart > altEnd else { return nil }
        let alt = String(line[line.index(line.startIndex, offsetBy: 2)..<altEnd])
        let path = String(line[line.index(after: pathStart)..<pathEnd])
        return (alt, path)
    }

    private static func extractSummary(_ line: String) -> String {
        guard let start = line.range(of: "<summary>"),
              let end = line.range(of: "</summary>") else { return "" }
        return String(line[start.upperBound..<end.lowerBound])
    }

    private static func splitPipeRow(_ line: String) -> [String] {
        // Drop leading/trailing pipes, split on |, trim whitespace.
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
