import Foundation

/// The Mac's own filesystem, read through FileManager off the main queue.
final class LocalFileSystemProvider: FileSystemProvider {
    static let shared = LocalFileSystemProvider()

    let displayName = "This Mac"
    let isRemote = false
    let identifier = "local"

    private let queue = DispatchQueue(label: "com.jupiterjvck.iterminal.files.local", qos: .userInitiated)

    func defaultPath() -> String { NSHomeDirectory() }

    func list(_ path: String, showHidden: Bool, completion: @escaping (Result<DirectoryListing, Error>) -> Void) {
        let resolved = (path as NSString).expandingTildeInPath
        queue.async {
            let url = URL(fileURLWithPath: resolved, isDirectory: true)
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
            do {
                let contents = try FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: keys,
                    options: showHidden ? [] : [.skipsHiddenFiles]
                )
                let items = contents.map { child -> FileItem in
                    let values = try? child.resourceValues(forKeys: Set(keys))
                    return FileItem(
                        name: child.lastPathComponent,
                        path: child.path,
                        isDirectory: values?.isDirectory ?? false,
                        size: (values?.fileSize).map(Int64.init),
                        modified: values?.contentModificationDate
                    )
                }
                let listing = DirectoryListing(path: url.standardizedFileURL.path, items: Self.sorted(items))
                DispatchQueue.main.async { completion(.success(listing)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func download(_ remotePath: String, to localURL: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async {
            do {
                if FileManager.default.fileExists(atPath: localURL.path) {
                    try FileManager.default.removeItem(at: localURL)
                }
                try FileManager.default.copyItem(at: URL(fileURLWithPath: remotePath), to: localURL)
                DispatchQueue.main.async { completion(.success(localURL)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func upload(_ localURL: URL, toDirectory remoteDirectory: String, completion: @escaping (Result<String, Error>) -> Void) {
        let destination = joinPath(remoteDirectory, localURL.lastPathComponent)
        queue.async {
            do {
                if FileManager.default.fileExists(atPath: destination) {
                    try FileManager.default.removeItem(atPath: destination)
                }
                try FileManager.default.copyItem(at: localURL, to: URL(fileURLWithPath: destination))
                DispatchQueue.main.async { completion(.success(destination)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func delete(_ item: FileItem, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            do {
                // Move to Trash rather than unlinking, so a mistake is
                // recoverable from Finder.
                try FileManager.default.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: nil)
                DispatchQueue.main.async { completion(.success(())) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func makeDirectory(named name: String, in parent: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let path = joinPath(parent, name)
        queue.async {
            do {
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
                DispatchQueue.main.async { completion(.success(())) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    static func sorted(_ items: [FileItem]) -> [FileItem] {
        items.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}
