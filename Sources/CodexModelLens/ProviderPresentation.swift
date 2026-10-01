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
    private func color(_ condition: ServiceCondition?) -> Color {
        switch condition {
        case .operational: .green
        case .degraded: .orange
        case .outage: .red
        case .unknown, nil: .secondary
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text(provider.statusScope).font(.caption.weight(.medium))
            Link(destination: provider.statusURL) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Circle().fill(color(status?.condition)).frame(width: 6, height: 6)
                    Text(status?.detail ?? "正在读取官方状态…").font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    Image(systemName: "arrow.up.right").font(.caption2).foregroundStyle(.tertiary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain)
            ForEach(status?.items ?? []) { item in
                Link(destination: item.url) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Circle().fill(color(item.condition)).frame(width: 6, height: 6)
                        Text(item.title + " · " + item.detail).frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }.font(.caption2).foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
            ForEach(Array((status?.events ?? []).prefix(3))) { event in
                Link(destination: event.url) {
                    HStack(alignment: .top, spacing: 8) {
                        Text(event.title).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if let date = event.updatedAt { Text(date.formatted(.dateTime.month().day())).monospacedDigit() }
                    }.font(.caption2).foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .help(status.map { "状态读取 \($0.fetchedAt.formatted(.dateTime.hour().minute()))" } ?? "状态读取中")
    }
}
