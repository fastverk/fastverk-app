// ChatBlockView — renders one chat.v1 Block. The eight kinds from event.proto:
// markdown, context, tool, list, fields, code, divider, table. User markdown is a
// trailing accent bubble; every other block is assistant content (leading). Tool
// cards show a live RUNNING/OK/ERROR state (re-sent in place by the model).

import SwiftUI

struct ChatBlockView: View {
    let block: ChatBlock

    var body: some View {
        switch block.kind {
        case let .markdown(text):
            if block.isUser {
                MarkdownText(text: text)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.tint, in: RoundedRectangle(cornerRadius: 16))
                    .foregroundStyle(.white)
                    .frame(maxWidth: 320, alignment: .trailing)
            } else {
                MarkdownText(text: text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        case let .context(icon, text):
            HStack(spacing: 6) {
                if !icon.isEmpty { Text(icon) }
                Text(text)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

        case let .tool(name, argsJson, state, summary):
            ToolCard(name: name, argsJson: argsJson, state: state, summary: summary)

        case let .list(title, items):
            ChatListCard(title: title, items: items)

        case let .fields(fields):
            FieldsCard(fields: fields)

        case let .code(language, text):
            CodeCard(language: language, text: text)

        case .divider:
            Divider().padding(.vertical, 2)

        case let .table(title, columns, rows):
            ChatTableCard(title: title, columns: columns, rows: rows)

        case .unknown:
            EmptyView()
        }
    }
}

private struct ToolCard: View {
    let name: String
    let argsJson: String
    let state: String
    let summary: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                stateGlyph
                Text(name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                if !summary.isEmpty {
                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if !argsJson.isEmpty, argsJson != "{}" {
                Text(argsJson)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var stateGlyph: some View {
        switch state {
        case "RUNNING": ProgressView().controlSize(.small)
        case "OK": Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case "ERROR": Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        default: Image(systemName: "wrench.and.screwdriver")
        }
    }
}

private struct ChatListCard: View {
    let title: String
    let items: [ChatBlock.ListItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !title.isEmpty {
                Text(title).font(.subheadline.weight(.semibold))
            }
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if !item.icon.isEmpty { Text(item.icon) }
                        Text(item.title).font(.body).lineLimit(1)
                    }
                    if !item.subtitle.isEmpty {
                        Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if !item.badges.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(item.badges, id: \.self) { badge in
                                Text(badge)
                                    .font(.caption2)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color(.tertiarySystemBackground), in: Capsule())
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if item.id != items.last?.id { Divider() }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct FieldsCard: View {
    let fields: [ChatBlock.Field]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(fields) { field in
                HStack(alignment: .top, spacing: 8) {
                    Text(field.key)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 110, alignment: .leading)
                    Text(field.value)
                        .font(.caption)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct CodeCard: View {
    let language: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !language.isEmpty {
                Text(language.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct ChatTableCard: View {
    let title: String
    let columns: [ChatBlock.Column]
    let rows: [[String: String]]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !title.isEmpty {
                Text(title).font(.subheadline.weight(.semibold))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    // Header
                    HStack(spacing: 12) {
                        ForEach(columns) { col in
                            Text(col.label.isEmpty ? col.key : col.label)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 120, alignment: .leading)
                        }
                    }
                    .padding(.bottom, 4)
                    Divider()
                    // Rows
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 12) {
                            ForEach(columns) { col in
                                Text(row[col.key] ?? "")
                                    .font(.caption)
                                    .lineLimit(1)
                                    .frame(width: 120, alignment: .leading)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }
}
