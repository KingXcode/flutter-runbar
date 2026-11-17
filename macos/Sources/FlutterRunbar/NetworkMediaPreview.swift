import SwiftUI
import AVKit
import ImageIO
import UniformTypeIdentifiers
import RunbarCore

struct NetworkMediaPreview: View {
    enum Kind: Equatable {
        case image, video

        init?(record: NetworkRecord) {
            self.init(contentType: record.contentType, filename: NetworkResponseExport.suggestedFilename(for: record))
        }

        init?(contentType: String, filename: String) {
            let mime = Self.mime(contentType)
            if mime.hasPrefix("image/") { self = .image; return }
            if mime.hasPrefix("video/") { self = .video; return }
            let ext = (filename as NSString).pathExtension
            if let type = UTType(filenameExtension: ext) {
                if type.conforms(to: .image) { self = .image; return }
                if type.conforms(to: .movie) || type.conforms(to: .video) { self = .video; return }
            }
            return nil
        }

        static func mime(_ contentType: String) -> String {
            contentType.split(separator: ";").first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        }
    }

    private enum Identity: Equatable {
        case captured(NetworkRecord)
        case request(UUID)
    }

    let kind: Kind
    private let identity: Identity
    private let contentType: String
    let load: () async throws -> NetworkResponseExport
    @State private var content: Content?
    @State private var error: String?

    private enum Content {
        case image(CGImage)
        case video(AVPlayer, PreviewFile)
    }

    init(kind: Kind, record: NetworkRecord, load: @escaping () async throws -> NetworkResponseExport) {
        self.kind = kind; self.load = load
        identity = .captured(record); contentType = record.contentType
    }

    init(kind: Kind, requestID: UUID, contentType: String, load: @escaping () async throws -> NetworkResponseExport) {
        self.kind = kind; self.load = load
        identity = .request(requestID); self.contentType = contentType
    }

    var body: some View {
        Group {
            if let content {
                switch content {
                case .image(let image):
                    Image(image, scale: 1, label: Text("响应图片预览")).resizable().scaledToFit().padding(12)
                case .video(let player, _):
                    LocalVideoPlayer(player: player)
                }
            } else if let error {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle").font(.title2)
                    Text(error).font(.caption).multilineTextAlignment(.center)
                }.foregroundStyle(.secondary).padding()
            } else {
                ProgressView("正在读取本地预览…").controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)).allowsHitTesting(false))
        .task(id: identity) { await loadPreview() }
        .onDisappear { clear() }
    }

    private func clear() {
        if case .video(let player, _) = content {
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        content = nil
        error = nil
    }

    private func loadPreview() async {
        clear()
        do {
            let export = try await load()
            let kind = kind, mime = Kind.mime(contentType)
            let file = try await Task.detached(priority: .utility) {
                try PreviewFile(export: export, mime: mime)
            }.value
            try Task.checkCancellation()
            switch kind {
            case .image:
                let image = try await Task.detached(priority: .utility) {
                    guard let source = CGImageSourceCreateWithURL(file.url as CFURL, nil),
                          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: 2048
                          ] as CFDictionary) else {
                        throw RunbarError.message("无法预览此图片格式。")
                    }
                    return image
                }.value
                try Task.checkCancellation()
                content = .image(image)
            case .video:
                let asset = AVURLAsset(url: file.url, options: [
                    AVURLAssetReferenceRestrictionsKey: NSNumber(value: AVAssetReferenceRestrictions.forbidAll.rawValue)
                ])
                guard try await asset.load(.isPlayable), !(try await asset.loadTracks(withMediaType: .video)).isEmpty else {
                    throw RunbarError.message("此视频格式无法在 macOS 上播放。")
                }
                try Task.checkCancellation()
                content = .video(AVPlayer(playerItem: AVPlayerItem(asset: asset)), file)
            }
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    private final class PreviewFile: Sendable {
        let directory: URL
        let url: URL

        init(export: NetworkResponseExport, mime: String) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("runbar-preview-\(UUID().uuidString)", isDirectory: true)
            let type = UTType(mimeType: mime)
            let mediaExtension = type.flatMap { $0.conforms(to: .image) || $0.conforms(to: .movie) || $0.conforms(to: .video)
                ? $0.preferredFilenameExtension : nil }
            let ext = mediaExtension ?? (export.filename as NSString).pathExtension
            url = directory.appendingPathComponent("response").appendingPathExtension(ext)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            do { try export.write(to: url) }
            catch { try? FileManager.default.removeItem(at: directory); throw error }
        }

        deinit { try? FileManager.default.removeItem(at: directory) }
    }
}

private struct LocalVideoPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.setAccessibilityLabel("响应视频预览")
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AVPlayerView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height, width.isFinite, height.isFinite else { return nil }
        return CGSize(width: max(0, width), height: max(0, height))
    }
}
