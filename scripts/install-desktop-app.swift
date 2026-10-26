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
// Keep the bundle identifier and data directory stable across the rename.
// Migrate the old Desktop filename too, including when both names exist.
let legacyDestination = destination.deletingLastPathComponent().appendingPathComponent("Flutter Runbar.app")
let destinations = destination.lastPathComponent == "Runbar.app" ? [destination, legacyDestination] : [destination]

func failure(_ message: String) -> NSError {
    NSError(domain: "RunbarInstaller", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
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
func validateExistingDestination(_ url: URL) throws {
    let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
    if values?.isSymbolicLink == true { throw failure("目标是符号链接，未替换：\(url.path)") }
    guard files.fileExists(atPath: url.path) else { return }
    let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
    guard values?.isDirectory == true, info?["CFBundleIdentifier"] as? String == identifier else {
        throw failure("目标不是 Runbar，未替换：\(url.path)")
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
    try destinations.forEach(validateExistingDestination)
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
    let stagedApp = staging.appendingPathComponent("Runbar.app")
    try files.createDirectory(at: staging, withIntermediateDirectories: true)
    try run("/usr/bin/ditto", ["--norsrc", "--noextattr", source.path, stagedApp.path])
    try run("/usr/bin/codesign", ["--verify", "--strict", stagedApp.path])
    let applications = runningApps()
    for application in applications {
        log("正在请求退出旧版 Runbar（PID \(application.processIdentifier)）…")
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
    guard runningApps().isEmpty else { throw failure("仍有 Runbar 在运行，未替换桌面应用。") }
    try destinations.forEach(validateExistingDestination)
    var movedApps: [(original: URL, saved: URL)] = []
    var installed = false
    do {
        for oldApp in destinations where files.fileExists(atPath: oldApp.path) {
            let saved = oldApp == destination ? backup : backup.deletingLastPathComponent().appendingPathComponent(oldApp.lastPathComponent)
            try files.createDirectory(at: saved.deletingLastPathComponent(), withIntermediateDirectories: true)
            try files.moveItem(at: oldApp, to: saved)
            movedApps.append((oldApp, saved))
        }
        try files.moveItem(at: stagedApp, to: destination)
        installed = true
        // Source and staging pass strict verification before installation.
        // Finder can immediately attach Desktop-position metadata to the root
        // bundle. Standard verification still validates signed code/resources
        // without racing Finder over that harmless, unsigned root metadata.
        try run("/usr/bin/codesign", ["--verify", destination.path])
    } catch {
        let installError = error
        do {
            if installed { try files.removeItem(at: destination) }
            for moved in movedApps.reversed() { try files.moveItem(at: moved.saved, to: moved.original) }
        } catch {
            throw failure("安装失败且恢复旧版失败：\(error.localizedDescription)。备份位于 \(backup.deletingLastPathComponent().path)。原始错误：\(installError.localizedDescription)")
        }
        throw installError
    }
    log("桌面应用已替换：\(destination.path)")
    for moved in movedApps { log("旧版备份：\(moved.saved.path)") }
    log("桌面安装完成。")
} catch {
    log("桌面安装失败：\(error.localizedDescription)")
    exit(1)
}
