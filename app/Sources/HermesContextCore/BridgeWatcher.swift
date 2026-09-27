import CoreServices
import Foundation

/// Watches the Hermes root with FSEvents and calls `onChange` once per burst of bridge changes.
/// Snapshots are replaced by atomic rename, so the watcher follows paths, never file descriptors.
public final class BridgeWatcher: @unchecked Sendable {
    private let location: BridgeLocation
    private let queue = DispatchQueue(label: "hermes-context.bridge-watcher")
    private let onChange: @Sendable () -> Void
    private var stream: FSEventStreamRef?

    public init(location: BridgeLocation, onChange: @escaping @Sendable () -> Void) {
        self.location = location
        self.onChange = onChange
    }

    deinit { stop() }

    public func start() {
        queue.sync {
            guard stream == nil else { return }
            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )
            let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<BridgeWatcher>.fromOpaque(info).takeUnretainedValue()
                let changed = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
                if changed.prefix(count).contains(where: BridgeLocation.isRelevant(path:)) {
                    watcher.onChange()
                }
            }
            let flags = FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer
            )
            guard let created = FSEventStreamCreate(
                nil, callback, &context, [location.root.path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, flags
            ) else { return }
            FSEventStreamSetDispatchQueue(created, queue)
            FSEventStreamStart(created)
            stream = created
        }
    }

    /// Never call from `onChange`: it runs on the watcher queue this waits on.
    public func stop() {
        queue.sync {
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }
}
