import SwiftUI
import Photos
import AVFoundation

/// The videos and pictures that are on this device, in one place. They are read from the Photos library on the device and shown here; nothing is copied or sent anywhere.
/// A video plays in StreamSetu's player like any other; a picture opens in a viewer that can be swiped through.
@MainActor @Observable
final class DeviceLibrary {
    enum Access: Sendable { case unknown, granted, limited, denied }

    private(set) var access: Access = .unknown
    private(set) var videos: [PHAsset] = []
    private(set) var pictures: [PHAsset] = []

    nonisolated static func access(from status: PHAuthorizationStatus) -> Access {
        switch status {
        case .authorized: .granted
        case .limited: .limited
        case .denied, .restricted: .denied
        case .notDetermined: .unknown
        @unknown default: .unknown
        }
    }

    func start() async {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
        access = Self.access(from: status)
        if access == .granted || access == .limited { load() }
    }

    private func load() {
        func fetch(_ type: PHAssetMediaType) -> [PHAsset] {
            let o = PHFetchOptions()
            o.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            o.fetchLimit = 3000
            let r = PHAsset.fetchAssets(with: type, options: o)
            var out: [PHAsset] = []; out.reserveCapacity(r.count)
            r.enumerateObjects { a, _, _ in out.append(a) }
            return out
        }
        videos = fetch(.video)
        pictures = fetch(.image)
    }

    /// A file the player can read for this video, or nil when it cannot be opened (a slow-motion video made of several parts, or one that could not be fetched from iCloud).
    static func playableURL(for asset: PHAsset) async -> URL? {
        await withCheckedContinuation { k in
            let o = PHVideoRequestOptions()
            o.isNetworkAccessAllowed = true
            o.deliveryMode = .highQualityFormat
            PHImageManager.default().requestAVAsset(forVideo: asset, options: o) { avAsset, _, _ in
                k.resume(returning: (avAsset as? AVURLAsset)?.url)
            }
        }
    }
}

private let thumbManager = PHCachingImageManager()

/// One square thumbnail.
private struct Thumb: View {
    let asset: PHAsset
    @State private var image: PlatformImage?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Rectangle().fill(Color.secondary.opacity(0.15))
            if let image { Image(platform: image).resizable().scaledToFill().transition(.opacity) }
            if asset.mediaType == .video {
                Text(Self.clock(asset.duration)).font(.caption2.monospacedDigit().weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 2).background(.black.opacity(0.55), in: Capsule()).padding(5)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipped()
        .contentShape(Rectangle())
        .task(id: asset.localIdentifier) {
            let o = PHImageRequestOptions(); o.deliveryMode = .opportunistic; o.isNetworkAccessAllowed = true; o.resizeMode = .fast
            let asset = asset
            let img: PlatformImage? = await withCheckedContinuation { k in
                var done = false
                thumbManager.requestImage(for: asset, targetSize: CGSize(width: 300, height: 300), contentMode: .aspectFill, options: o) { image, info in
                    guard !done else { return }
                    if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }          // wait for the real one
                    done = true; k.resume(returning: image)
                }
            }
            withAnimation(.easeOut(duration: 0.2)) { image = img }
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded()); return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

extension Image {
    init(platform image: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: image)
        #else
        self.init(uiImage: image)
        #endif
    }
}

struct OnYourDeviceView: View {
    @Environment(\.container) private var container
    @State private var library = DeviceLibrary()
    @State private var tab = Tab.videos
    @State private var viewing: Int?
    @State private var busy: String?
    @State private var note: String?

    enum Tab: String, CaseIterable, Identifiable { case videos = "Videos", pictures = "Pictures", files = "Files"; var id: Self { self } }

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 160), spacing: 3)]

    var body: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $tab) { ForEach(Tab.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 16).padding(.vertical, 10)
            content.animation(.easeInOut(duration: 0.2), value: tab)
        }
        .navigationTitle("On Your Device")
        .task { await library.start() }
        .overlay(alignment: .bottom) {
            if let busy { Text(busy).font(.callout).padding(.horizontal, 14).padding(.vertical, 8).background(.regularMaterial, in: Capsule()).padding(.bottom, 20).transition(.opacity) }
            else if let note { Text(note).font(.callout).padding(.horizontal, 14).padding(.vertical, 8).background(.regularMaterial, in: Capsule()).padding(.bottom, 20).transition(.opacity) }
        }
        .animation(.easeInOut(duration: 0.2), value: busy)
        .sheet(item: Binding(get: { viewing.map { Viewing(index: $0) } }, set: { viewing = $0?.index })) { v in
            PictureViewer(assets: library.pictures, start: v.index)
        }
    }

    private struct Viewing: Identifiable { let index: Int; var id: Int { index } }

    @ViewBuilder private var content: some View {
        switch tab {
        case .files: FilesView()
        case .videos, .pictures:
            switch library.access {
            case .unknown: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .denied: denied
            case .granted, .limited:
                let items = tab == .videos ? library.videos : library.pictures
                if items.isEmpty { empty } else {
                    ScrollView {
                        if library.access == .limited { Text("StreamSetu can see only the photos you chose. Change this in Settings > Privacy > Photos.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.bottom, 6) }
                        LazyVGrid(columns: columns, spacing: 3) {
                            ForEach(Array(items.enumerated()), id: \.element.localIdentifier) { i, asset in
                                Thumb(asset: asset).onTapGesture { open(asset, index: i) }
                            }
                        }.padding(.horizontal, 3)
                    }
                }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: tab == .videos ? "video" : "photo").font(.system(size: 40)).foregroundStyle(.secondary)
            Text(tab == .videos ? "No videos on this device" : "No pictures on this device").font(.headline)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var denied: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.fill").font(.system(size: 36)).foregroundStyle(.secondary)
            Text("Photos access is off").font(.headline)
            Text("Allow StreamSetu to see your photos and videos to browse them here. They stay on this device; nothing is copied or sent.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Open Settings") { NotificationPermission.openPhotosSettings() }.buttonStyle(.borderedProminent)
        }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func open(_ asset: PHAsset, index: Int) {
        if asset.mediaType == .image { viewing = index; return }
        Task {
            busy = "Preparing the video…"
            let url = await DeviceLibrary.playableURL(for: asset)
            busy = nil
            if let url { FilesPlayer.play(file: url, title: "Video from this device", container: container) }
            else { note = "That video could not be opened."; try? await Task.sleep(nanoseconds: 2_500_000_000); note = nil }
        }
    }
}

/// A picture, full size, that can be pinched, and swiped (or stepped with the arrows) to the next and the one before.
private struct PictureViewer: View {
    let assets: [PHAsset]
    @State var index: Int
    @Environment(\.dismiss) private var dismiss
    @State private var image: PlatformImage?
    @State private var scale: CGFloat = 1
    @State private var settled: CGFloat = 1

    init(assets: [PHAsset], start: Int) { self.assets = assets; _index = State(initialValue: start) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image {
                Image(platform: image).resizable().scaledToFit().scaleEffect(scale)
                    .gesture(MagnificationGesture().onChanged { scale = max(1, settled * $0) }.onEnded { _ in settled = scale })
                    .transition(.opacity)
            } else { ProgressView().tint(.white) }
            HStack {
                step("chevron.left", -1)
                Spacer()
                step("chevron.right", 1)
            }.padding(.horizontal, 12)
            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title).symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.4)) }.buttonStyle(.plain)
                }.padding(14)
                Spacer()
                Text("\(index + 1) of \(assets.count)").font(.caption).foregroundStyle(.white.opacity(0.8)).padding(.bottom, 14)
            }
        }
        .gesture(DragGesture(minimumDistance: 30).onEnded { v in
            guard scale <= 1.01 else { return }
            if v.translation.width < -60 { go(1) } else if v.translation.width > 60 { go(-1) }
        })
        .task(id: index) { await load() }
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 480)
        .onKeyPress(.leftArrow) { go(-1); return .handled }
        .onKeyPress(.rightArrow) { go(1); return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
        #endif
    }

    @ViewBuilder private func step(_ symbol: String, _ by: Int) -> some View {
        let target = index + by
        if assets.indices.contains(target) {
            Button { go(by) } label: { Image(systemName: symbol).font(.title2.weight(.semibold)).foregroundStyle(.white).padding(10).background(.black.opacity(0.35), in: Circle()) }.buttonStyle(.plain)
        } else { Color.clear.frame(width: 44, height: 44) }
    }

    private func go(_ by: Int) {
        guard assets.indices.contains(index + by) else { return }
        withAnimation(.easeInOut(duration: 0.2)) { index += by; scale = 1; settled = 1 }
    }

    private func load() async {
        guard assets.indices.contains(index) else { return }
        let asset = assets[index]
        let o = PHImageRequestOptions(); o.deliveryMode = .opportunistic; o.isNetworkAccessAllowed = true
        let img: PlatformImage? = await withCheckedContinuation { k in
            var done = false
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 2400, height: 2400), contentMode: .aspectFit, options: o) { image, info in
                if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                guard !done else { return }; done = true; k.resume(returning: image)
            }
        }
        withAnimation(.easeOut(duration: 0.2)) { image = img }
    }
}
