import Foundation
import Darwin

@main struct ConversionIsolationChecks {
    static func main() async throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--probe-loopback", let port = UInt16(CommandLine.arguments[2]) {
            let result = connectLoopback(port)
            print("CONNECT_RESULT:\(result)")
            return
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let resources = CommandLine.arguments.count > 2 ? [URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)] : []
        let job = root.appendingPathComponent("sandbox"), outside = root.appendingPathComponent("outside-fixture.txt")
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
        try Data("synthetic fixture only".utf8).write(to: outside)
        var checks: [String] = []
        func check(_ value: Bool, _ label: String) throws { guard value else { throw NSError(domain: "ConversionIsolationChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }; checks.append(label) }
        let bytecodePolicy = try await ConversionProcess.run(URL(fileURLWithPath: "/usr/bin/printenv"), arguments: ["PYTHONDONTWRITEBYTECODE"], directory: job, resources: resources)
        try check(String(decoding: bytecodePolicy, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "1", "child environment disables Python bytecode generation")
        let readOnlyResource = root.appendingPathComponent("runtime-resource", isDirectory: true)
        try FileManager.default.createDirectory(at: readOnlyResource, withIntermediateDirectories: true)
        let cacheAttempt = readOnlyResource.appendingPathComponent("generated.pyc")
        do { _ = try await ConversionProcess.run(URL(fileURLWithPath: "/usr/bin/touch"), arguments: [cacheAttempt.path], directory: job, resources: resources + [readOnlyResource]); throw DocumentConversionError.invalidOutput }
        catch DocumentConversionError.conversionFailed { }
        try check(!FileManager.default.fileExists(atPath: cacheAttempt.path), "child cannot write bytecode into an approved read-only runtime resource")
        do { _ = try await ConversionProcess.run(URL(fileURLWithPath: "/bin/cat"), arguments: [outside.path], directory: job, resources: resources); throw DocumentConversionError.invalidOutput }
        catch DocumentConversionError.conversionFailed { checks.append("child cannot read a synthetic file outside its approved job resources") }
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw DocumentConversionError.invalidOutput }; defer { close(listener) }
        var address = loopback(0)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(listener, 2) == 0 else { throw DocumentConversionError.invalidOutput }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let located = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) } }
        guard located == 0 else { throw DocumentConversionError.invalidOutput }
        let port = UInt16(bigEndian: address.sin_port)
        guard connectLoopback(port) == 0 else { throw DocumentConversionError.invalidOutput }
        let accepted = accept(listener, nil, nil); if accepted >= 0 { close(accepted) }
        let probe = job.appendingPathComponent("socket-probe")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[0]), to: probe)
        let networkResult = try await ConversionProcess.run(probe, arguments: ["--probe-loopback", String(port)], directory: job, resources: resources)
        try check(String(decoding: networkResult, as: UTF8.self).contains("CONNECT_RESULT:\(EPERM)"), "child connect to an available loopback listener is explicitly denied with EPERM by the conversion sandbox")
        let start = Date()
        let task = Task { try await ConversionProcess.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], directory: job, resources: resources) }
        try await Task.sleep(nanoseconds: 100_000_000); task.cancel()
        do { _ = try await task.value; throw DocumentConversionError.invalidOutput } catch is CancellationError { }
        try check(Date().timeIntervalSince(start) < 3, "cancellation stops and awaits the local child promptly")
        let report: [String: Any] = ["passed": true, "checks": checks, "realProviderRequests": 0, "externalNetworkRequests": 0, "resourceDirectories": resources.map(\.path), "unsandboxedLoopbackConnect": "success", "sandboxedLoopbackConnectErrno": EPERM]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]).write(to: root.appendingPathComponent("conversion-isolation-checks.json"), options: .atomic)
        print("Passed \(checks.count) conversion isolation checks")
    }
    private static func loopback(_ port: UInt16) -> sockaddr_in {
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1"); return address
    }
    private static func connectLoopback(_ port: UInt16) -> Int32 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return errno }; defer { close(descriptor) }
        var address = loopback(port)
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        return result == 0 ? 0 : errno
    }
}
