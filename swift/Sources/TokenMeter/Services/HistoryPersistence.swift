import Foundation

/// 本地留存错误只暴露操作，不携带路径、文件内容或 Foundation 原始诊断。
enum HistoryPersistenceError: LocalizedError, Equatable {
    case readFailed
    case decodeFailed
    case encodeFailed
    case directoryFailed
    case writeFailed
    case deleteFailed

    var errorDescription: String? {
        switch self {
        case .readFailed: return "无法读取本机用量历史，原文件未覆盖"
        case .decodeFailed: return "本机用量历史格式损坏，原文件未覆盖"
        case .encodeFailed: return "无法编码本机用量历史，原文件未覆盖"
        case .directoryFailed: return "无法创建本机用量历史目录"
        case .writeFailed: return "无法保存本机用量历史"
        case .deleteFailed: return "无法修正本机用量历史，原文件仍保留"
        }
    }
}

/// 默认 IO 使用真实文件与原子写入；回归可注入单次失败，不触碰个人留存。
struct HistoryFileIO {
    var read: (URL) throws -> Data = { try Data(contentsOf: $0) }
    var write: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
    var createDirectory: (URL) throws -> Void = {
        try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
    }
    var remove: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    var contents: (URL) throws -> [String] = {
        try FileManager.default.contentsOfDirectory(atPath: $0.path)
    }

    func readJSON<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value? {
        let data: Data
        do {
            data = try read(url)
        } catch {
            if Self.isMissing(error) { return nil }
            throw HistoryPersistenceError.readFailed
        }
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw HistoryPersistenceError.decodeFailed }
    }

    func writeJSON<Value: Encodable>(_ value: Value, to url: URL, sortedKeys: Bool = false) throws {
        let encoder = JSONEncoder()
        if sortedKeys { encoder.outputFormatting = [.sortedKeys] }
        let data: Data
        do { data = try encoder.encode(value) }
        catch { throw HistoryPersistenceError.encodeFailed }
        do { try createDirectory(url.deletingLastPathComponent()) }
        catch { throw HistoryPersistenceError.directoryFailed }
        do { try write(data, url) }
        catch { throw HistoryPersistenceError.writeFailed }
    }

    func removeChecked(_ url: URL) throws {
        do { try remove(url) }
        catch {
            guard Self.isMissing(error) else { throw HistoryPersistenceError.deleteFailed }
        }
    }

    func contentsChecked(_ directory: URL) throws -> [String] {
        do { return try contents(directory) }
        catch {
            if Self.isMissing(error) { return [] }
            throw HistoryPersistenceError.readFailed
        }
    }

    private static func isMissing(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSCocoaErrorDomain else { return false }
        return nsError.code == CocoaError.fileReadNoSuchFile.rawValue
            || nsError.code == CocoaError.fileNoSuchFile.rawValue
    }
}
