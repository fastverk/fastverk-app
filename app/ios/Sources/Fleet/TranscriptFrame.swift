// TranscriptFrame — decodes one Claude Code `stream-json` line (the fleet
// transcript SSE payload) into a rendered frame. There is no fastverk proto for
// these frames; the shape is Anthropic's agent stream-json (the same the web's
// fleet.js traverses): a top-level `type` with `system` / `assistant` / `user`
// (tool results) / `result`, tolerant of unknown types. Frames are complete
// messages, not token deltas — the runner doesn't pass --include-partial-messages.

import Foundation
import MeridianUI

/// One decoded transcript frame.
enum TranscriptFrame {
    case system(subtype: String)
    case assistant([AssistantBlock])
    case toolResults([ToolResult])
    case result(TranscriptResult)
    /// A build log line, an SSE `error` event, or an undecodable/unknown frame.
    case raw(String)
}

/// A content block inside an `assistant` frame.
enum AssistantBlock: Identifiable {
    case text(String)
    case toolUse(name: String, input: String)
    case other(String)

    var id: String {
        switch self {
        case let .text(t): return "t:\(t.hashValue)"
        case let .toolUse(name, input): return "u:\(name):\(input.hashValue)"
        case let .other(s): return "o:\(s.hashValue)"
        }
    }
}

/// A tool result inside a `user` frame.
struct ToolResult: Identifiable {
    let toolUseId: String
    let content: String
    var id: String { toolUseId }
}

/// The terminal `result` frame.
struct TranscriptResult {
    let subtype: String
    let costUSD: Double?
    let durationMs: Double?
    let inputTokens: Int?
    let outputTokens: Int?
}

extension TranscriptFrame {
    /// Decode one stream-json line. `agent` transcripts are JSON; `build` logs are
    /// plain text (pass `isJSON: false` to render them verbatim).
    static func decode(_ line: String, isJSON: Bool = true) -> TranscriptFrame {
        guard isJSON, let v = try? JSONValue.parse(line) else { return .raw(line) }
        switch v["type"].asString {
        case "system":
            return .system(subtype: v["subtype"].asString ?? "")
        case "assistant":
            let blocks = v.get("message.content").asArray ?? []
            return .assistant(blocks.map(mapAssistantBlock))
        case "user":
            let blocks = v.get("message.content").asArray ?? []
            let results = blocks.compactMap { block -> ToolResult? in
                guard block["type"].asString == "tool_result" else { return nil }
                return ToolResult(
                    toolUseId: block["tool_use_id"].asString ?? "",
                    content: contentText(block["content"])
                )
            }
            return results.isEmpty ? .raw(line) : .toolResults(results)
        case "result":
            return .result(TranscriptResult(
                subtype: v["subtype"].asString ?? "",
                costUSD: v["total_cost_usd"].asDouble,
                durationMs: v["duration_ms"].asDouble,
                inputTokens: v.get("usage.input_tokens").asDouble.map { Int($0) },
                outputTokens: v.get("usage.output_tokens").asDouble.map { Int($0) }
            ))
        default:
            return .raw(line)
        }
    }

    private static func mapAssistantBlock(_ b: JSONValue) -> AssistantBlock {
        switch b["type"].asString {
        case "text":
            return .text(b["text"].asString ?? "")
        case "tool_use":
            let name = b["name"].asString ?? "tool"
            let input = (try? b["input"].serialized()) ?? ""
            return .toolUse(name: name, input: input)
        default:
            return .other((try? b.serialized()) ?? "")
        }
    }

    /// A tool_result's `content` is a string or an array of typed parts
    /// (`[{type:"text", text:…}]`). Join the text parts; else compact the JSON.
    private static func contentText(_ v: JSONValue) -> String {
        if let s = v.asString { return s }
        if let arr = v.asArray {
            let texts = arr.compactMap { $0["text"].asString }
            if !texts.isEmpty { return texts.joined(separator: "\n") }
        }
        return (try? v.serialized()) ?? ""
    }
}
