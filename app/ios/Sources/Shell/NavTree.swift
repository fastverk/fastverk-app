// NavTree — the server-driven console navigation, as served by botnoc-web
// `GET /api/shell` (meridian.ui.v1.NavTree in proto3-JSON, camelCase; see
// botnoc web/src/shell.rs). Decoded with Codable rather than a swift-protobuf
// binding: the endpoint is JSON and the legacy MeridianProto has no NavTree
// message. The proto `oneof target` flattens to sibling keys in proto3-JSON, so
// panelId / viewId are optional and mutually exclusive.

import Foundation

struct NavTree: Decodable {
    var roots: [NavNode] = []
}

struct NavNode: Decodable, Identifiable, Hashable {
    let id: String
    let label: String
    var icon: String?
    var panelId: String?
    var viewId: String?
    var children: [NavNode]?
    var defaultOpen: Bool?
    var badge: String?

    /// A leaf has no children — it targets a panel (or, in Phase 1, a view).
    var isLeaf: Bool { (children ?? []).isEmpty }

    static func == (lhs: NavNode, rhs: NavNode) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
