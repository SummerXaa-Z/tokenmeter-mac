import CryptoKit
import Darwin
import Foundation
import Security

enum UpdateSafetyError: LocalizedError {
    case manualDownload(String)
    case invalidPackage(String)
    case toolFailed(String)

    var errorDescription: String? {
        switch self {
        case .manualDownload(let reason), .invalidPackage(let reason), .toolFailed(let reason): return reason
        }
    }
}

struct UpdateSigningIdentity {
    let requirement: String
    let leafCertificate: Data
    let isAdHoc: Bool
}

struct UpdateBundleIdentity {
    let bundleID: String
    let version: String
    let architectures: Set<String>
    let signing: UpdateSigningIdentity?
}

enum UpdateSafety {
    // This identifier also owns the app's preferences and Keychain access.
    static let bundleID = "com.deepseek.monitor.mac"

    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    // Trust starts at the signed app the user has already installed. Ad-hoc signatures
    // authenticate bytes, but provide no publisher identity that survives a release.
    static func trustAnchor(for current: UpdateBundleIdentity) throws -> String {
        guard current.bundleID == bundleID,
              let signing = current.signing,
              !signing.isAdHoc, !signing.leafCertificate.isEmpty,
              !signing.requirement.isEmpty else {
            throw UpdateSafetyError.manualDownload("当前应用没有可连续验证的发布者签名，请从官方发布页手动下载安装。")
        }
        // A designated requirement may allow several publishers. Pin the installed
        // certificate as well; certificate replacement deliberately requires review.
        let certificateHash = Insecure.SHA1.hash(data: signing.leafCertificate)
            .map { String(format: "%02x", $0) }.joined()
        return "(\(signing.requirement)) and certificate leaf = H\"\(certificateHash)\""
    }

    static func validate(current: UpdateBundleIdentity, candidate: UpdateBundleIdentity,
                         releaseVersion: String, architecture: String,
                         matchesRequirement: (String) throws -> Bool) throws {
        let requirement = try trustAnchor(for: current)
        guard candidate.bundleID == bundleID else {
            throw UpdateSafetyError.invalidPackage("安装包的应用标识不匹配。")
        }
        guard candidate.version == releaseVersion else {
            throw UpdateSafetyError.invalidPackage("安装包版本与发布版本不一致。")
        }
        guard candidate.architectures.contains(architecture) else {
            throw UpdateSafetyError.invalidPackage("安装包不支持当前运行架构。")
        }
        guard let installedSigning = current.signing,
              let candidateSigning = candidate.signing,
              !candidateSigning.isAdHoc,
              candidateSigning.leafCertificate == installedSigning.leafCertificate,
              try matchesRequirement(requirement) else {
            throw UpdateSafetyError.manualDownload("安装包的发布者签名无法与当前应用连续验证，请从官方发布页手动下载安装。")
        }
    }

    static func inspect(_ app: URL) throws -> UpdateBundleIdentity {
        let code = try staticCode(at: app)
        // Read identity and metadata only after validating the signature that seals them.
        guard SecStaticCodeCheckValidity(code, validationFlags, nil) == errSecSuccess else {
            throw UpdateSafetyError.manualDownload("应用签名无效，无法安全自动更新，请手动下载安装。")
        }
        guard let bundle = Bundle(url: app),
              let identifier = bundle.bundleIdentifier,
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let executable = bundle.executableURL else {
            throw UpdateSafetyError.invalidPackage("安装包缺少有效的应用信息。")
        }
        let executableName = executable.lastPathComponent
        guard executableName == "TokenMeter",
              executable.deletingLastPathComponent().standardizedFileURL == app.appendingPathComponent("Contents/MacOS").standardizedFileURL else {
            throw UpdateSafetyError.invalidPackage("安装包的执行文件路径无效。")
        }
        let architectures = try architectures(of: executable)
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any] else {
            throw UpdateSafetyError.manualDownload("无法读取发布者签名，请手动下载安装。")
        }
        guard info[kSecCodeInfoIdentifier as String] as? String == identifier else {
            throw UpdateSafetyError.invalidPackage("应用签名标识与 Bundle 标识不一致。")
        }
        let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? []
        var designated: SecRequirement?
        var requirementString: CFString?
        let hasRequirement = SecCodeCopyDesignatedRequirement(code, [], &designated) == errSecSuccess
        if hasRequirement, let designated {
            _ = SecRequirementCopyString(designated, [], &requirementString)
        }
        let signature = UpdateSigningIdentity(
            requirement: requirementString as String? ?? "",
            leafCertificate: certificates.first.map { SecCertificateCopyData($0) as Data } ?? Data(),
            // Ad-hoc signatures have no certificate chain. Treat every certificate-less
            // signature as unanchored rather than guessing a publisher from its name.
            isAdHoc: certificates.isEmpty)
        return UpdateBundleIdentity(bundleID: identifier, version: version, architectures: architectures, signing: signature)
    }

    static func matchesRequirement(_ requirement: String, app: URL) throws -> Bool {
        var compiled: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess,
              let compiled else { return false }
        return SecStaticCodeCheckValidity(try staticCode(at: app), validationFlags, compiled) == errSecSuccess
    }

    // Parse Mach-O headers directly; automatic updates must not require users to
    // install Xcode/Command Line Tools just to obtain lipo.
    static func architectures(of executable: URL) throws -> Set<String> {
        let file = try FileHandle(forReadingFrom: executable)
        defer { try? file.close() }
        let bytes = [UInt8](try file.read(upToCount: 4096) ?? Data())
        guard bytes.count >= 8 else { throw UpdateSafetyError.invalidPackage("安装包的执行文件格式无效。") }
        let magic = Array(bytes.prefix(4))
        let littleEndian: Bool
        let fatEntrySize: Int?
        switch magic {
        case [0xce, 0xfa, 0xed, 0xfe], [0xcf, 0xfa, 0xed, 0xfe]: littleEndian = true; fatEntrySize = nil
        case [0xfe, 0xed, 0xfa, 0xce], [0xfe, 0xed, 0xfa, 0xcf]: littleEndian = false; fatEntrySize = nil
        case [0xca, 0xfe, 0xba, 0xbe]: littleEndian = false; fatEntrySize = 20
        case [0xca, 0xfe, 0xba, 0xbf]: littleEndian = false; fatEntrySize = 32
        case [0xbe, 0xba, 0xfe, 0xca]: littleEndian = true; fatEntrySize = 20
        case [0xbf, 0xba, 0xfe, 0xca]: littleEndian = true; fatEntrySize = 32
        default: throw UpdateSafetyError.invalidPackage("安装包的执行文件不是 Mach-O。")
        }
        func integer(at offset: Int) -> UInt32 {
            let slice = bytes[offset..<(offset + 4)]
            return (littleEndian ? Array(slice.reversed()) : Array(slice)).reduce(0) { ($0 << 8) | UInt32($1) }
        }
        let offsets: [Int]
        if let size = fatEntrySize {
            let count = Int(integer(at: 4))
            guard (1...64).contains(count), 8 + count * size <= bytes.count else {
                throw UpdateSafetyError.invalidPackage("安装包的通用执行文件头无效。")
            }
            offsets = (0..<count).map { 8 + $0 * size }
        } else { offsets = [4] }
        return Set(offsets.compactMap { offset -> String? in
            switch integer(at: offset) {
            case 0x01000007: return "x86_64"
            case 0x0100000c: return "arm64"
            default: return nil
            }
        })
    }

    private static var validationFlags: SecCSFlags {
        SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
    }

    private static func staticCode(at app: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateSafetyError.manualDownload("无法验证应用签名，请手动下载安装。")
        }
        return code
    }

    // Fixed executable paths, no shell expansion, bounded waits and output draining.
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 30) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        try process.run()
        // Tool output here is small (lipo/plist). Read concurrently so a corrupt image
        // cannot fill the pipe and deadlock the process before the timeout.
        let reader = DispatchQueue(label: "TokenMeter.update.tool-output")
        let result = UpdateToolOutput()
        let outputComplete = DispatchGroup()
        outputComplete.enter()
        reader.async {
            result.data = output.fileHandleForReading.readDataToEndOfFile()
            outputComplete.leave()
        }
        if completed.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if completed.wait(timeout: .now() + 1) == .timedOut {
                _ = kill(process.processIdentifier, SIGKILL)
                _ = completed.wait(timeout: .now() + 2)
            }
            throw UpdateSafetyError.toolFailed("更新验证超时。")
        }
        outputComplete.wait()
        guard process.terminationStatus == 0 else {
            throw UpdateSafetyError.toolFailed("更新验证工具执行失败。")
        }
        return String(data: result.data, encoding: .utf8) ?? ""
    }
}

private final class UpdateToolOutput: @unchecked Sendable {
    // One writer; read after DispatchGroup has completed.
    var data = Data()
}

struct PreparedUpdate {
    let stagedApp: URL
    let stagingDirectory: URL
    let target: URL
    let backup: URL
    let requirement: String
    let version: String
}

enum UpdatePreparation {
    static func prepare(dmg: URL, jobDirectory: URL, target: URL, current: UpdateBundleIdentity, version: String,
                        run: (String, [String]) throws -> String = { try UpdateSafety.run($0, $1) },
                        inspect: (URL) throws -> UpdateBundleIdentity = UpdateSafety.inspect,
                        matchesRequirement: (String, URL) throws -> Bool = { try UpdateSafety.matchesRequirement($0, app: $1) }) throws -> PreparedUpdate {
        let manager = FileManager.default
        let mount = jobDirectory.appendingPathComponent("mount")
        try manager.createDirectory(at: mount, withIntermediateDirectories: false)
        var device: String?
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", device ?? mount.path]) }
        let attached = try run("/usr/bin/hdiutil", ["attach", "-plist", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, dmg.path])
        device = try mountedDevice(plist: Data(attached.utf8), expectedMount: mount)
        let candidates = try manager.contentsOfDirectory(at: mount, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            .filter { $0.pathExtension == "app" }
        guard candidates.count == 1, let source = candidates.first, source.lastPathComponent == "TokenMeter.app",
              try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory == true,
              try source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw UpdateSafetyError.invalidPackage("安装包必须包含唯一、完整的应用。")
        }
        let stagingDirectory = target.deletingLastPathComponent().appendingPathComponent(".TokenMeter-update-\(UUID().uuidString)")
        try manager.createDirectory(at: stagingDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let stagedApp = stagingDirectory.appendingPathComponent("TokenMeter.app")
        do {
            // Preserve quarantine and all other extended attributes. Gatekeeper remains
            // authoritative when LaunchServices launches the copied application.
            _ = try run("/usr/bin/ditto", [source.path, stagedApp.path])
            let candidate = try inspect(stagedApp)
            try UpdateSafety.validate(current: current, candidate: candidate, releaseVersion: version, architecture: UpdateSafety.architecture) {
                try matchesRequirement($0, stagedApp)
            }
            return PreparedUpdate(stagedApp: stagedApp, stagingDirectory: stagingDirectory, target: target,
                                  backup: target.deletingLastPathComponent().appendingPathComponent(".TokenMeter-backup-\(UUID().uuidString).app"),
                                  requirement: try UpdateSafety.trustAnchor(for: current), version: version)
        } catch {
            try? manager.removeItem(at: stagingDirectory)
            throw error
        }
    }

    static func mountedDevice(plist: Data, expectedMount: URL) throws -> String {
        guard let result = try PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
              let entities = result["system-entities"] as? [[String: Any]] else {
            throw UpdateSafetyError.invalidPackage("安装镜像的挂载信息无效。")
        }
        let mounted = entities.filter { $0["mount-point"] != nil }
        guard mounted.count == 1, let volume = mounted.first,
              let path = volume["mount-point"] as? String,
              URL(fileURLWithPath: path).standardizedFileURL == expectedMount.standardizedFileURL,
              let device = volume["dev-entry"] as? String, device.hasPrefix("/dev/disk"),
              device.dropFirst("/dev/disk".count).allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "s") }) else {
            throw UpdateSafetyError.invalidPackage("安装镜像没有唯一的预期挂载卷。")
        }
        return device
    }
}

enum UpdateInstallerScript {
    // The downloaded image is never executed. Revalidate the exact staged copy after
    // the old process exits; move the old app aside before switching and retain it.
    static let source = """
    #!/bin/bash
    set -euo pipefail
    umask 077
    rollback() {
      if [ -e "$TM_BACKUP" ]; then
        if [ -e "$TM_TARGET" ]; then
          "$TM_MOVE" "$TM_TARGET" "$TM_STAGE" || return 1
        fi
        "$TM_MOVE" "$TM_BACKUP" "$TM_TARGET" || return 1
      fi
    }
    finish() {
      local status="$1"
      [ "$status" = 0 ] && return
      set +e
      printf 'failed\\n' > "$TM_RESULT"
      rollback || return
      # Never reopen a target whose signature changed or whose original PID is alive.
      if { [ "$TM_PID" = 0 ] || ! /bin/kill -0 "$TM_PID" 2>/dev/null; } &&
         [ -d "$TM_TARGET" ] && [ ! -L "$TM_TARGET" ] &&
         "$TM_VERIFY" --verify --deep --strict --all-architectures -R "$TM_REQUIREMENT" "$TM_TARGET"; then
        "$TM_OPEN" "$TM_TARGET"
      fi
    }
    trap 'finish "$?"' EXIT
    for ((i=0; i<120; i++)); do
      if [ "$TM_PID" = 0 ] || ! /bin/kill -0 "$TM_PID" 2>/dev/null; then break; fi
      /bin/sleep 0.5
    done
    if [ "$TM_PID" != 0 ] && /bin/kill -0 "$TM_PID" 2>/dev/null; then exit 1; fi
    [ -d "$TM_TARGET" ] && [ ! -L "$TM_TARGET" ] && [ -d "$TM_STAGE" ] && [ ! -L "$TM_STAGE" ] && [ ! -e "$TM_BACKUP" ] || exit 1
    "$TM_VERIFY" --verify --deep --strict --all-architectures -R "$TM_REQUIREMENT" "$TM_STAGE" || exit 1
    [ "$("$TM_PLIST" -c 'Print :CFBundleIdentifier' "$TM_STAGE/Contents/Info.plist")" = 'com.deepseek.monitor.mac' ] || exit 1
    [ "$("$TM_PLIST" -c 'Print :CFBundleShortVersionString' "$TM_STAGE/Contents/Info.plist")" = "$TM_VERSION" ] || exit 1
    [ "$("$TM_PLIST" -c 'Print :CFBundleExecutable' "$TM_STAGE/Contents/Info.plist")" = 'TokenMeter' ] || exit 1
    ARCHITECTURES=$("$TM_ARCH_VERIFY" -b "$TM_STAGE/Contents/MacOS/TokenMeter") || exit 1
    case "$TM_ARCH" in
      arm64) [[ "$ARCHITECTURES" = *arm64* ]] || exit 1 ;;
      x86_64) [[ "$ARCHITECTURES" = *x86_64* ]] || exit 1 ;;
      *) exit 1 ;;
    esac
    "$TM_VERIFY" --verify --deep --strict --all-architectures -R "$TM_REQUIREMENT" "$TM_TARGET" || exit 1
    "$TM_MOVE" "$TM_TARGET" "$TM_BACKUP" || exit 1
    "$TM_MOVE" "$TM_STAGE" "$TM_TARGET" || exit 1
    printf 'complete\\n' > "$TM_RESULT"
    if ! "$TM_OPEN" "$TM_TARGET"; then exit 1; fi
    trap - EXIT
    exit 0
    """

    static func environment(target: URL, stagedApp: URL, backup: URL, requirement: String, processID: Int32,
                            version: String = "4.0.0", architecture: String = UpdateSafety.architecture,
                            resultFile: URL,
                            verifyCommand: String = "/usr/bin/codesign", moveCommand: String = "/bin/mv", openCommand: String = "/usr/bin/open",
                            plistCommand: String = "/usr/libexec/PlistBuddy", architectureCommand: String = "/usr/bin/file") -> [String: String] {
        ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C",
         "TM_TARGET": target.path, "TM_STAGE": stagedApp.path, "TM_BACKUP": backup.path,
         "TM_REQUIREMENT": requirement, "TM_PID": String(processID),
         "TM_VERSION": version, "TM_ARCH": architecture,
         "TM_RESULT": resultFile.path,
         "TM_VERIFY": verifyCommand, "TM_MOVE": moveCommand, "TM_OPEN": openCommand,
         "TM_PLIST": plistCommand, "TM_ARCH_VERIFY": architectureCommand]
    }
}

struct UpdateResultStore {
    let directory: URL

    static var live: UpdateResultStore {
        UpdateResultStore(directory: RuntimeEnvironment.applicationSupportDirectory.appendingPathComponent("Updates", isDirectory: true))
    }

    private var resultFile: URL { directory.appendingPathComponent("last-install-result") }

    var hasFailure: Bool {
        guard let values = try? resultFile.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) <= 64,
              let result = try? String(contentsOf: resultFile, encoding: .utf8) else { return false }
        return result.trimmingCharacters(in: .whitespacesAndNewlines) == "failed"
    }

    func prepareResultFile() throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard directory.standardizedFileURL == directory.resolvingSymlinksInPath().standardizedFileURL,
              (try? resultFile.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw UpdateSafetyError.invalidPackage("更新状态目录不能是符号链接。")
        }
        guard manager.createFile(atPath: resultFile.path, contents: Data("pending\n".utf8), attributes: [.posixPermissions: 0o600]) else {
            throw UpdateSafetyError.toolFailed("无法保存更新状态。")
        }
        return resultFile
    }
}
