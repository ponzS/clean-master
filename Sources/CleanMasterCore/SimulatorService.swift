import Foundation
import Darwin

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ value: Data) { lock.lock(); data = value; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}

public enum ToolRunner {
    // Arguments never pass through a shell. Both pipes are drained concurrently.
    public static func run(_ arguments: [String], timeout: TimeInterval = 30) throws -> Data {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl"] + arguments
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output; process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        try process.run()
        let group = DispatchGroup(), stdout = OutputBuffer(), stderr = OutputBuffer()
        for (handle, buffer) in [(output.fileHandleForReading, stdout), (errors.fileHandleForReading, stderr)] {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                buffer.set(handle.readDataToEndOfFile()); group.leave()
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false, cancelled = false
        while ended.wait(timeout: .now() + 0.1) == .timedOut {
            cancelled = Task.isCancelled
            timedOut = Date() >= deadline
            if cancelled || timedOut { break }
        }
        if timedOut || cancelled {
            process.terminate()
            if ended.wait(timeout: .now() + 2) == .timedOut { kill(process.processIdentifier, SIGKILL) }
        }
        _ = group.wait(timeout: .now() + 3)
        if cancelled { throw CancellationError() }
        if timedOut { throw CleanError.command("Xcode 工具响应超时。请确认 Xcode 已完成首次启动设置后重试。") }
        let errorText = String(data: stderr.get(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            throw CleanError.command(String((errorText.isEmpty ? "Xcode 工具执行失败。" : errorText).prefix(500)))
        }
        return stdout.get()
    }
}

public struct SimulatorDevice: Decodable, Sendable {
    public let udid: String
    public let name: String
    public let state: String
    public let dataPath: String?
    public var runtime: String = ""
    enum CodingKeys: String, CodingKey { case udid, name, state, dataPath }
}

public struct SimulatorRuntime: Decodable, Sendable {
    public let identifier: String
    public let runtimeIdentifier: String?
    public let version: String
    public let build: String
    public let path: String
    public let sizeBytes: Int64?
    public let deletable: Bool?
}

public enum SimulatorService {
    private struct DeviceEnvelope: Decodable { let devices: [String: [SimulatorDevice]] }
    public static func devices() throws -> [SimulatorDevice] {
        let envelope = try JSONDecoder().decode(DeviceEnvelope.self, from: ToolRunner.run(["list", "devices", "--json"]))
        return envelope.devices.flatMap { runtime, devices in
            devices.map { var device = $0; device.runtime = runtime; return device }
        }
    }
    public static func runtimes() throws -> [SimulatorRuntime] {
        Array(try JSONDecoder().decode([String: SimulatorRuntime].self, from: ToolRunner.run(["runtime", "list", "--json"])).values)
    }
    public static func validID(_ id: String) -> Bool { UUID(uuidString: id) != nil }
    public static func validRuntimePath(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return ["/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime", "/Library/Developer/CoreSimulator/Images"]
            .contains { root in PathPolicy.isInside(url, URL(fileURLWithPath: root)) && url.path != root }
    }
}
