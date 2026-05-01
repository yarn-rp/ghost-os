// AnnotationsStrip.swift - Horizontal scroll of recent annotation thumbnails
// in the menu popover.
//
// Each tile shows: region.png thumbnail + caption (app · "5m ago"). Click
// reveals the annotation directory in Finder. Right-click copies the id
// to the clipboard so an agent prompt can `flow42 annotations show <id>`.

import AppKit
import Flow42Core
import SwiftUI

struct AnnotationsStrip: View {
    @ObservedObject var model: AnnotationsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.dashed")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Annotations")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                if !model.entries.isEmpty {
                    Text("· \(model.entries.count)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Text("⌘⇧A")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)

            if model.entries.isEmpty {
                emptyHint
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.entries) { entry in
                            AnnotationTile(entry: entry)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                }
                .frame(height: 96)
            }
        }
    }

    private var emptyHint: some View {
        Text("Press ⌘⇧A to capture a region. The agent will get the screenshot + element tree underneath.")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            .padding(.top, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AnnotationTile: View {
    let entry: AnnotationEntry
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            thumbnail
                .frame(width: 96, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            hovered
                                ? Color.accentColor.opacity(0.6)
                                : Color.primary.opacity(0.1),
                            lineWidth: hovered ? 1.5 : 1
                        )
                )
            Text(entry.caption)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 96, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture {
            NSWorkspace.shared.open(URL(fileURLWithPath: AnnotationStore.annotationDir(id: entry.id)))
        }
        .contextMenu {
            Button("Copy id") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.id, forType: .string)
            }
            Button("Copy `flow42 annotations show <id>`") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    "flow42 annotations show \(entry.id)", forType: .string
                )
            }
            Divider()
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([
                    URL(fileURLWithPath: entry.regionPath)
                ])
            }
        }
        .help("\(entry.caption) · click to open · right-click for options")
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let img = entry.imageThumbnail {
            Image(nsImage: img)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Color.primary.opacity(0.05)
                Image(systemName: "photo")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
