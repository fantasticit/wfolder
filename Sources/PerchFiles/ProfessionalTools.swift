import SwiftUI

enum ProfessionalPage: String, Identifiable, CaseIterable {
    case delivery = "项目交付", resume = "可恢复传输", compare = "版本对比", search = "内容搜索", inbox = "项目收件箱"
    var id: Self { self }

    var action: String {
        switch self {
        case .delivery: "打包交付文件"
        case .resume: "复制大文件"
        case .compare: "比较两个版本"
        case .search: "查找文件里的文字"
        case .inbox: "整理下载和收件"
        }
    }

    var detail: String {
        switch self {
        case .delivery: "生成 ZIP 和校验文件，可以回看每次交付"
        case .resume: "中途暂停、断开磁盘或重启后可以继续复制"
        case .compare: "并排查看两份 PDF、图片或文件夹的差异"
        case .search: "查找文档、源码和图片里的文字"
        case .inbox: "选择一个收件文件夹，把文件归档到项目"
        }
    }

    var symbol: String {
        switch self {
        case .delivery: "shippingbox"
        case .resume: "arrow.clockwise.circle"
        case .compare: "square.split.2x1"
        case .search: "doc.text.magnifyingglass"
        case .inbox: "tray"
        }
    }
}

@MainActor
final class ProfessionalTools {
    let storage: ProfessionalStorage
    let history: DeliveryHistory
    let transfers: ResumableTransfers
    let inbox: ProjectInbox
    let entitlement: ProfessionalEntitlement

    init(storage: ProfessionalStorage = ProfessionalStorage()) {
        self.storage = storage
        history = DeliveryHistory(storage: storage)
        transfers = ResumableTransfers(storage: storage)
        inbox = ProjectInbox(storage: storage)
        entitlement = ProfessionalEntitlement(storage: storage)
    }
}

struct ProfessionalToolsView: View {
    let workspace: BrowserWorkspace
    @ViewState var page: ProfessionalPage?
    var files: [URL] = []
    var openSearch: (URL?) -> Void

    private var selectedFolder: URL? {
        guard files.count == 1, FileStamp(files[0])?.directory == true else { return nil }
        return files[0]
    }

    private var entitlement: ProfessionalEntitlement { workspace.professional.entitlement }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if let page {
                    Button {
                        self.page = nil
                    } label: {
                        Label("所有工具", systemImage: "chevron.left")
                    }
                    Text(page.action).font(.headline).accessibilityAddTraits(.isHeader)
                } else {
                    Text("文件工具").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                }
                Spacer()
                Button("关闭") { workspace.presentedTool = nil }.keyboardShortcut(.cancelAction)
            }
            Divider()
            if entitlement.status != .development {
                ProfessionalLicenseView(entitlement: entitlement)
            }
            if entitlement.status.allowsTools {
                tools
            } else {
                ContentUnavailableView("需要 wfolder Pro 许可证", systemImage: "lock")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(16)
        .frame(width: 860, height: 570)
        .onAppear { entitlement.refresh() }
    }

    private var toolList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(ProfessionalPage.allCases) { tool in
                if tool != ProfessionalPage.allCases.first { Divider().padding(.leading, 46) }
                Button {
                    if tool == .search { openSearch(selectedFolder) }
                    else { page = tool }
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: tool.symbol)
                            .font(.title3)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 26)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tool.action).fontWeight(.semibold)
                            Text(tool.detail).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 65)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tool.action)
                .accessibilityHint(tool.detail)
            }
            Spacer()
        }
    }

    @ViewBuilder private var tools: some View {
        switch page {
        case nil:
            toolList
        case .delivery:
            DeliveryView(workspace: workspace, files: files)
        case .resume:
            ResumableTransfersView(workspace: workspace, files: files.filter { !$0.hasDirectoryPath })
        case .compare: VersionCompareView(files: files, history: workspace.professional.history, storage: workspace.professional.storage)
        case .search: toolList
        case .inbox: InboxView(workspace: workspace)
        }
    }
}
