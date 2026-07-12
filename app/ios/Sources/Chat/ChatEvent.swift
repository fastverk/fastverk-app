// ChatEvent — the chat.v1 HostEvent model + decoder (Phase C).
//
// The console assistant (botnoc-chat, reached via /api/noc-agent) streams
// proto3-JSON HostEvents (camelCase) over SSE: each frame carries exactly one of
// `block` / `status` / `done` / `error`, ordered by a per-conversation `seq`.
// There are no token deltas — an assistant utterance is one whole block, and a
// re-sent `blockId` REPLACES the prior block (tool cards flip RUNNING→OK/ERROR
// this way). The client keeps an ordered dict keyed by blockId and upserts.
// Decoded via JSONValue (the block `kind` is a dynamic oneof key).

import Foundation
import MeridianUI

/// One SSE frame: exactly one of block/status/done/error is non-nil.
struct HostEvent {
    var seq: UInt64?
    var block: ChatBlock?
    var status: ChatStatus?
    var done: TurnDone?
    var error: TurnError?

    static func decode(_ data: String) -> HostEvent? {
        guard let v = try? JSONValue.parse(data) else { return nil }
        var event = HostEvent(seq: v["seq"].asDouble.map { UInt64($0) })
        if !v["block"].isNull {
            event.block = ChatBlock.from(v["block"])
        } else if !v["status"].isNull {
            event.status = ChatStatus(
                state: v.get("status.state").asString ?? "IDLE",
                detail: v.get("status.detail").asString ?? ""
            )
        } else if !v["done"].isNull {
            event.done = TurnDone(stopReason: v.get("done.stopReason").asString ?? "")
        } else if !v["error"].isNull {
            event.error = TurnError(message: v.get("error.message").asString ?? "Something went wrong.")
        } else {
            return nil
        }
        return event
    }
}

struct ChatStatus: Equatable {
    let state: String   // IDLE | THINKING | WORKING
    let detail: String
    var isBusy: Bool { state == "THINKING" || state == "WORKING" }

    static let idle = ChatStatus(state: "IDLE", detail: "")
}

struct TurnDone { let stopReason: String }
struct TurnError { let message: String }

/// One rendered transcript unit. Identity is `blockId` so a re-sent block updates
/// in place.
struct ChatBlock: Identifiable {
    let blockId: String
    let role: String    // "user" | "assistant"
    let kind: Kind
    var id: String { blockId }
    var isUser: Bool { role == "user" }

    enum Kind {
        case markdown(String)
        case context(icon: String, text: String)
        case tool(name: String, argsJson: String, state: String, summary: String)
        case list(title: String, items: [ListItem])
        case fields([Field])
        case code(language: String, text: String)
        case divider
        case table(title: String, columns: [Column], rows: [[String: String]])
        case unknown
    }

    struct ListItem: Identifiable {
        let title: String
        let subtitle: String
        let icon: String
        let badges: [String]
        var id: String { title + subtitle }
    }

    struct Field: Identifiable {
        let key: String
        let value: String
        var id: String { key }
    }

    struct Column: Identifiable {
        let key: String
        let label: String
        var id: String { key }
    }

    /// Decode a `block` object, probing which kind oneof key is present.
    static func from(_ v: JSONValue) -> ChatBlock {
        let blockId = v["blockId"].asString ?? ""
        let role = v["role"].asString ?? "assistant"
        return ChatBlock(blockId: blockId, role: role, kind: kind(from: v))
    }

    private static func kind(from v: JSONValue) -> Kind {
        if !v["markdown"].isNull {
            return .markdown(v.get("markdown.text").asString ?? "")
        }
        if !v["context"].isNull {
            return .context(icon: v.get("context.icon").asString ?? "",
                            text: v.get("context.text").asString ?? "")
        }
        if !v["tool"].isNull {
            return .tool(
                name: v.get("tool.name").asString ?? "tool",
                argsJson: v.get("tool.argsJson").asString ?? "",
                state: v.get("tool.state").asString ?? "RUNNING",
                summary: v.get("tool.summary").asString ?? ""
            )
        }
        if !v["list"].isNull {
            let items = v.rows("list.items").map { i in
                ListItem(
                    title: i["title"].asString ?? "",
                    subtitle: i["subtitle"].asString ?? "",
                    icon: i["icon"].asString ?? "",
                    badges: (i["badges"].asArray ?? []).compactMap { $0.asString }
                )
            }
            return .list(title: v.get("list.title").asString ?? "", items: items)
        }
        if !v["fields"].isNull {
            let fields = v.rows("fields.fields").map { f in
                Field(key: f["key"].asString ?? "", value: f["value"].asString ?? "")
            }
            return .fields(fields)
        }
        if !v["code"].isNull {
            return .code(language: v.get("code.language").asString ?? "",
                         text: v.get("code.text").asString ?? "")
        }
        if !v["divider"].isNull {
            return .divider
        }
        if !v["table"].isNull {
            let columns = v.rows("table.columns").map { c in
                Column(key: c["key"].asString ?? "", label: c["label"].asString ?? "")
            }
            let rows: [[String: String]] = v.rows("table.rows").map { r in
                guard case let .object(cells) = r["cells"] else { return [:] }
                return cells.reduce(into: [:]) { acc, kv in acc[kv.key] = kv.value.asString ?? "" }
            }
            return .table(title: v.get("table.title").asString ?? "", columns: columns, rows: rows)
        }
        return .unknown
    }
}
