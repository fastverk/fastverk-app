// ProcessRpcInvoker — the Dashboard's meridian transport. Instead of a native
// gRPC/Swift stack, it shells out to the `fvd-json` Rust shim, which calls fvd
// over its Unix socket and prints snake_case JSON. The shim inherits this
// process's environment (notably $FASTVERK_SOCKET, set by the tray), so it
// dials the same socket the daemon listens on.

import Foundation
import MeridianUI

struct ProcessRpcInvoker: RpcInvoker {
    /// Absolute path to the `fvd-json` binary.
    let shimURL: URL

    /// Locate `fvd-json`: an explicit `$FASTVERK_FVD_JSON` override (used by
    /// `bazel run`), else a sibling of this executable (the .app bundle's
    /// Contents/MacOS, where the tray spawns us from).
    static func locate() -> ProcessRpcInvoker? {
        if let override = ProcessInfo.processInfo.environment["FASTVERK_FVD_JSON"],
           !override.isEmpty {
            return ProcessRpcInvoker(shimURL: URL(fileURLWithPath: override))
        }
        if let exe = Bundle.main.executableURL {
            let sibling = exe.deletingLastPathComponent().appendingPathComponent("fvd-json")
            if FileManager.default.isExecutableFile(atPath: sibling.path) {
                return ProcessRpcInvoker(shimURL: sibling)
            }
        }
        return nil
    }

    func invoke(service: String, method: String, request: JSONValue) async throws -> JSONValue {
        let requestArg = try request.serialized()

        let proc = Process()
        proc.executableURL = shimURL
        proc.arguments = [service, method, requestArg]
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err

        do {
            try proc.run()
        } catch {
            throw RpcError.transport("spawn fvd-json: \(error.localizedDescription)")
        }

        // Read before waiting so a large response can't deadlock on a full pipe.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            let msg = String(decoding: errData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw RpcError.transport(msg.isEmpty ? "fvd-json exited \(proc.terminationStatus)" : msg)
        }

        do {
            return try JSONValue.parse(outData)
        } catch {
            throw RpcError.decode("\(error)")
        }
    }
}
