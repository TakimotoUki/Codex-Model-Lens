import SwiftUI
import ModelLensCore

struct ModelProbeView: View {
    @Bindable var store: LensStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("模型核验", systemImage: "checkmark.shield").font(.title2.weight(.semibold))
                Spacer(); Button("完成") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
            }.padding(22)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("直接读取独立测试的原始响应").font(.headline)
                    Text("使用已登录的官方 Codex CLI 发送一次极短测试，消耗少量 Codex 额度。临时登录文件在结束后删除。结果只属于该测试，不会作为已有桌面任务的模型证据。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        TextField("模型名称", text: $store.probeModel).textFieldStyle(.roundedBorder).disabled(store.isProbing)
                        if store.isProbing {
                            ProgressView().controlSize(.small)
                            Button("取消") { store.cancelProbe() }
                        } else {
                            Button("开始一次核验") { store.startProbe() }.buttonStyle(.glassProminent)
                                .disabled(store.probeModel.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    if let error = store.probeError { Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange) }
                    if store.isProbing { Text("正在读取响应，最长等待 90 秒…").font(.caption).foregroundStyle(.secondary) }
                    ForEach(store.probeReports.prefix(10)) { report in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Label(report.label, systemImage: report.isConfirmed ? report.hasDifference ? "arrow.triangle.branch" : "checkmark.circle.fill" : "questionmark.circle")
                                    .font(.headline).foregroundStyle(report.isConfirmed && !report.hasDifference ? .blue : .orange)
                                Spacer(); Text(report.testedAt, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                            }
                            LabeledContent("请求模型", value: report.requestedModel)
                            LabeledContent("输出响应模型", value: report.deliveredModels.isEmpty ? "未返回" : report.deliveredModels.joined(separator: "、"))
                            ForEach(report.responses) { response in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(response.hasOutput ? "实际输出 · \(response.effectiveModels.joined(separator: "、"))" : "无输出响应 · \(response.effectiveModels.joined(separator: "、"))")
                                        .font(.caption.weight(.medium))
                                    if !response.headerModels.isEmpty && Set(response.models) != Set(response.headerModels) && !response.models.isEmpty {
                                        Text("普通 model 字段：\(response.models.joined(separator: "、"))；优先采用模型响应头。")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Text(response.responseID).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                            HStack {
                                Text("\(report.duration, specifier: "%.1f") 秒 · \(report.frames) 个传输事件").font(.caption).foregroundStyle(.secondary)
                                Spacer(); Button("复制证据") { store.copyProbe(report) }.buttonStyle(.link)
                            }
                        }.padding(16).background(.quaternary.opacity(0.2), in: .rect(cornerRadius: 12))
                    }
                    if store.probeReports.isEmpty && !store.isProbing {
                        Label("核验记录会保存在本机，响应正文不会保存。", systemImage: "lock").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.frame(width: 660, height: 620)
    }
}
