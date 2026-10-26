import AppKit
import Darwin
import Foundation

// Keep the installer outside the old app: quitting Runbar may stop the command
// that built it. The detached mode survives that process group's termination.
let detached = CommandLine.arguments.dropFirst().first == "--detached"
let arguments = Array(CommandLine.arguments.dropFirst(detached ? 2 : 1))
guard arguments.count == 4 else {
    fputs("Usage: install-desktop-app [--detached] SOURCE DESTINATION BACKUP LOG\n", stderr)
    exit(2)
}
let source = URL(fileURLWithPath: arguments[0])
let destination = URL(fileURLWithPath: arguments[1])
let backup = URL(fileURLWithPath: arguments[2])
let logURL = URL(fileURLWithPath: arguments[3])
let identifier = "dev.kingxcode.flutter-runbar"
let files = FileManager.default

func failure(_ message: String) -> NSError {
    NSError(domain: "FlutterRunbarInstaller", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}
func log(_ message: String) {
    if !detached { print(message) }
    if !files.fileExists(atPath: logURL.path) { files.createFile(atPath: logURL.path, contents: nil) }
    if let handle = try? FileHandle(forWritingTo: logURL) {
        defer { try? handle.close() }
        do { try handle.seekToEnd(); try handle.write(contentsOf: Data((message + "\n").utf8)) }
        catch { fputs("安装日志写入失败：\(error.localizedDescription)\n", stderr) }
    }
}
@discardableResult
func run(_ executable: String, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = String(decoding: data, as: UTF8.self)
    guard process.terminationStatus == 0 else { throw failure("\(executable) 失败：\(output)") }
    return output
}
func validateExistingDestination() throws {
    let values = try? destination.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
    if values?.isSymbolicLink == true { throw failure("目标是符号链接，未替换：\(destination.path)") }
    guard files.fileExists(atPath: destination.path) else { return }
    let info = NSDictionary(contentsOf: destination.appendingPathComponent("Contents/Info.plist"))
    guard values?.isDirectory == true, info?["CFBundleIdentifier"] as? String == identifier else {
        throw failure("目标不是 Flutter Runbar，未替换：\(destination.path)")
    }
}
func runningApps() -> [NSRunningApplication] {
    NSRunningApplication.runningApplications(withBundleIdentifier: identifier).filter { !$0.isTerminated }
}
func isHostedByRunbar(_ apps: [NSRunningApplication]) -> Bool {
    let appPIDs = Set(apps.map(\.processIdentifier))
    var parent = getppid()
    var visited = Set<pid_t>()
    while parent > 1, visited.insert(parent).inserted {
        if appPIDs.contains(parent) { return true }
        guard let output = try? run("/bin/ps", ["-o", "ppid=", "-p", String(parent)]),
              let next = Int32(output.trimmingCharacters(in: .whitespacesAndNewlines)) else { break }
        parent = next
    }
    return false
}

do {
    try validateExistingDestination()
    if !detached, isHostedByRunbar(runningApps()) {
        // No inherited output pipe or process group: the app can now stop its
        // own packaging command without killing the actual desktop installer.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        process.arguments = ["--detached"] + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        log("正在由独立安装器退出旧版并替换桌面应用。安装日志：\(logURL.path)")
        exit(10) // Explicit handoff; the shell must not claim installation is finished.
    }
    if detached {
        if setpgid(0, 0) != 0, getpgrp() != getpid() { throw failure("无法隔离安装器进程组，未退出旧版。") }
        signal(SIGHUP, SIG_IGN)
        Thread.sleep(forTimeInterval: 1) // Let Runbar finish its packaging command first.
    }
    try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    let staging = destination.deletingLastPathComponent().appendingPathComponent(".runbar-install-\(UUID().uuidString)")
    defer { try? files.removeItem(at: staging) }
    let stagedApp = staging.appendingPathComponent("Flutter Runbar.app")
    try files.createDirectory(at: staging, withIntermediateDirectories: true)
    try run("/usr/bin/ditto", ["--norsrc", "--noextattr", source.path, stagedApp.path])
    try run("/usr/bin/codesign", ["--verify", "--strict", stagedApp.path])
    let applications = runningApps()
    for application in applications {
        log("正在请求退出旧版 Flutter Runbar（PID \(application.processIdentifier)）…")
        guard application.terminate() || application.isTerminated else {
            throw failure("旧版拒绝退出，未替换桌面应用。")
        }
    }
    let deadline = Date().addingTimeInterval(120)
    while applications.contains(where: { !$0.isTerminated }) {
        guard Date() < deadline else {
            throw failure("旧版尚未退出，未替换桌面应用。若取消了退出或仍有任务，请处理后重新打包。")
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    guard runningApps().isEmpty else { throw failure("仍有 Flutter Runbar 在运行，未替换桌面应用。") }
    try validateExistingDestination()
    var movedOldApp = false
    if files.fileExists(atPath: destination.path) {
        try files.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.moveItem(at: destination, to: backup)
        movedOldApp = true
    }
    do {
        try files.moveItem(at: stagedApp, to: destination)
        // Finder can attach these metadata attributes when a Desktop item is
        // replaced. Remove only packaging detritus from the newly copied bundle;
        // never strip quarantine or other security attributes.
        let attributes = try run("/usr/bin/xattr", [destination.path]).split(separator: "\n").map(String.init)
        for attribute in ["com.apple.FinderInfo", "com.apple.ResourceFork"] where attributes.contains(attribute) {
            try run("/usr/bin/xattr", ["-d", attribute, destination.path])
        }
        try run("/usr/bin/codesign", ["--verify", "--strict", destination.path])
    } catch {
        if movedOldApp {
            try? files.removeItem(at: destination)
            try files.moveItem(at: backup, to: destination)
        }
        throw error
    }
    log("桌面应用已替换：\(destination.path)")
    if movedOldApp { log("旧版备份：\(backup.path)") }
    log("桌面安装完成。")
} catch {
    log("桌面安装失败：\(error.localizedDescription)")
    exit(1)
}
