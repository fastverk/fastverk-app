// MarkdownText — renders a string of lightweight markdown as SwiftUI Text.
//
// The transcript's assistant text and chat's markdown blocks are markdown (bold,
// italic, `code`, links). SwiftUI's AttributedString(markdown:) handles the
// inline subset; block constructs (lists, headings) degrade to text. Whitespace
// is preserved so multi-line assistant prose keeps its line breaks. Shared by the
// agent-transcript viewer (Phase B) and chat (Phase C).

import SwiftUI

struct MarkdownText: View {
    let text: String

    var body: some View {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(
                allowsExtendedAttributes: true,
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) {
            Text(attributed)
        } else {
            Text(text)
        }
    }
}
