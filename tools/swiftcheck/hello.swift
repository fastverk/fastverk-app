// P0 toolchain probe: confirms rules_swift builds a swift_binary that links
// SwiftUI + Foundation on this host (Command Line Tools only, Bazel 9.1.0).
// Not shipped — delete once app/dashboard builds.
import SwiftUI
import Foundation

struct ProbeView: View {
    var body: some View {
        Text("fastverk swift toolchain ok")
    }
}

// Reference the type so the optimizer can't drop the SwiftUI import, then exit
// without entering a run loop (this is a build/link probe, not the real app).
let _ = ProbeView()
FileHandle.standardError.write("swiftcheck: SwiftUI linked\n".data(using: .utf8)!)
