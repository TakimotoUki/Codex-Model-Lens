import SwiftUI
import ModelLensCore

struct DiagnosticsView: View {
    let store: LensStore
    @Environment(\.dismiss) private var dismiss
    @State private var showExplanation = false
    @State private var bodyHeight: CGFloat = 360

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "doc.text.magnifyingglass").font(.title2).foregroundStyle(.blue)
                    .frame(width: 42, height: 42).glassEffect(.regular, in: .rect(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text("检测范围").font(.title2.weight(.semibold))
                    Text("本机数据源与模型证据").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }.buttonStyle(.glassProminent).keyboardShortcut(.cancelAction)
            }.padding(22)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 20) {
                        metric("本次任务", store.latestScan.threads.count)
                        metric("增量文件", store.latestScan.filesRead)
                        metric("服务端证据", store.evidenceCount)
                    }.padding(15).background(.quaternary.opacity(0.22), in: .rect(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 10) {
                        Text("读取范围").font(.headline)
                        VStack(spacing: 0) {
                            ForEach(Array((store.latestScan.sources ?? []).enumerated()), id: \.element.id) { index, source in
                                sourceRow(source)
                                if index + 1 < (store.latestScan.sources?.count ?? 0) { Divider().padding(.leading, 42) }
                            }
                            if store.latestScan.sources?.isEmpty ?? true {
                                Text(store.isScanning ? "正在读取数据源…" : "尚未完成首次扫描")
                                    .font(.caption).foregroundStyle(.secondary).padding(14)
                            }
                        }.background(.quaternary.opacity(0.14), in: .rect(cornerRadius: 12))
                    }
                    if !store.latestScan.diagnostics.isEmpty {
                        DisclosureGroup("\(store.latestScan.diagnostics.count) 项读取提示") {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(store.latestScan.diagnostics) { diagnostic in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(diagnostic.message).font(.caption)
                                        Text(diagnostic.source).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                                    }
                                }
                            }.padding(.top, 10)
                        }.foregroundStyle(.orange)
                    }
                    DisclosureGroup("如何判断模型", isExpanded: $showExplanation) {
                        VStack(alignment: .leading, spacing: 12) {
                            explanation("轮次模型", "该轮客户端请求的模型", "slider.horizontal.3")
                            explanation("服务端模型", "原始响应的 model、模型响应头或明确路由事件", "arrow.down.doc")
                            explanation("安全缓冲", "缓冲状态与可重试模型，不能单独确认交付模型", "hourglass")
                            Text("运行状态依据本机活动判断。其他设备、未保存的事件和没有模型字段的响应无法从历史中恢复。")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }.padding(.top, 12)
                    }
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bodyHeight = $0 }
            }.frame(height: min(540, bodyHeight))
            Divider()
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: store.latestScan.diagnostics.isEmpty ? "checkmark.circle" : "info.circle")
                    .foregroundStyle(store.latestScan.diagnostics.isEmpty ? .blue : .orange)
                Text("读取成功不代表响应公开了模型；缺少服务端字段时保持未确认。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }.padding(18)
        }.frame(width: 660).fixedSize(horizontal: false, vertical: true)
    }
    private func metric(_ title: String, _ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(count)").font(.title3.weight(.semibold).monospacedDigit())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func sourceRow(_ source: ScanSourceStatus) -> some View {
        HStack(spacing: 11) {
            Image(systemName: source.state == .available ? "checkmark.circle.fill" : source.state == .disabled ? "minus.circle" : "info.circle")
                .foregroundStyle(source.state == .available ? .blue : source.state == .disabled || source.state == .missing ? .secondary : .orange)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(source.title).font(.subheadline.weight(.medium))
                Text(source.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(source.state.label).font(.caption).foregroundStyle(.secondary)
        }.padding(.horizontal, 14).padding(.vertical, 11).help(source.path)
    }
    private func explanation(_ title: String, _ text: String, _ icon: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 20)
            Text(title).fontWeight(.medium).frame(width: 75, alignment: .leading)
            Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.caption)
    }
}
