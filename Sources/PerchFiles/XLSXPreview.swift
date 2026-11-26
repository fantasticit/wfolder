import SwiftUI

struct XLSXPreview: View {
    let workbook: XLSXWorkbook

    @ViewState private var selected: XLSXWorkbook.Sheet?
    @ViewState private var source: XLSXSheetSource?
    @ViewState private var loadError: String?

    init(workbook: XLSXWorkbook) {
        self.workbook = workbook
        _selected = ViewState(initialValue: workbook.sheets.first)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let current = selected {
                HStack {
                    if workbook.sheets.count > 1 {
                        Picker("工作表", selection: $selected) {
                            ForEach(workbook.sheets) { sheet in
                                Text(sheet.name).tag(Optional(sheet))
                            }
                        }
                        .pickerStyle(.menu)
                    } else {
                        Label(current.name, systemImage: "tablecells")
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(.bar)
                Divider()

                if let source, source.sheet == current {
                    PagedPreview(source: source).id(source.id)
                } else if let loadError {
                    ContentUnavailableView(loadError, systemImage: "exclamationmark.tablecells")
                        .frame(maxHeight: .infinity)
                } else {
                    ProgressView().controlSize(.small).frame(maxHeight: .infinity)
                }
            } else {
                ContentUnavailableView("没有可预览的工作表", systemImage: "tablecells")
                    .frame(maxHeight: .infinity)
            }
        }
        .task(id: selected) {
            loadError = nil
            guard let sheet = selected else { return }
            do {
                source = try XLSXSheetSource(workbook: workbook, sheet: sheet)
            } catch {
                source = nil
                loadError = error.localizedDescription
            }
        }
    }
}
