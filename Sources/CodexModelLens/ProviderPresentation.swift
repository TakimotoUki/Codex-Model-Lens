import SwiftUI
import AppKit
import ModelLensCore

struct ProviderIcon: View {
    let provider: UsageProvider
    private static let images: [UsageProvider: NSImage] = {
        Dictionary(uniqueKeysWithValues: UsageProvider.allCases.compactMap { provider in
            guard let url = Bundle.main.url(forResource: provider.rawValue, withExtension: "png", subdirectory: "ProviderIcons"),
                  let image = NSImage(contentsOf: url) else { return nil }
            image.isTemplate = true
            return (provider, image)
        })
    }()
    var body: some View {
        if let image = Self.images[provider] {
            Image(nsImage: image).resizable().scaledToFit().frame(width: 22, height: 22)
        } else {
            Text(provider.title.prefix(1)).font(.caption.weight(.semibold)).frame(width: 22, height: 22)
        }
    }
}

struct ProviderStatusView: View {
    let provider: UsageProvider
    let status: ServiceStatus?
    private var color: Color {
        switch status?.condition {
        case .operational: .green
        case .degraded: .orange
        case .outage: .red
        case .unknown, nil: .secondary
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Link(destination: provider.statusURL) {
                HStack(spacing: 7) {
                    Circle().fill(color).frame(width: 6, height: 6)
                    Text(status?.detail ?? "正在读取官方状态…").font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }.help(status.map { "状态读取 \($0.fetchedAt.formatted(.dateTime.hour().minute()))" } ?? "状态读取中")
    }
}
