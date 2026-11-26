import AppKit

final class FileSelectionCheckbox: NSButton {
    var onToggle: (() -> Void)?

    init() {
        super.init(frame: .zero)
        setButtonType(.switch)
        controlSize = .small
        title = ""
        target = self
        action = #selector(toggle)
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    func configure(visible: Bool, name: String, selected: Bool, onToggle: @escaping () -> Void) {
        isHidden = !visible
        setAccessibilityLabel("选择 " + name)
        state = selected ? .on : .off
        self.onToggle = visible ? onToggle : nil
    }

    @objc private func toggle() { onToggle?() }
}
