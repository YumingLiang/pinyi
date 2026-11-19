import SwiftUI
import UIKit

/// 一行文字。组合态留在系统输入框里，不送进正文；组合结束后才整次提交。
struct ShapeTextLineField: UIViewRepresentable {
    var title: String
    var text: String
    var identifier: String
    var isFocused: Bool
    var onCommit: (String) -> Void
    var onBegin: () -> Void
    var onReturn: () -> Void

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.placeholder = title
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.returnKeyType = .next
        field.accessibilityIdentifier = identifier
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(ShapeTextFieldAdapter.editingChanged(_:)), for: .editingChanged)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        let adapter = context.coordinator
        adapter.onCommit = onCommit
        adapter.onBegin = onBegin
        adapter.onReturn = onReturn
        // 组合中不把已提交正文写回去，否则会拆掉输入法。
        if field.markedTextRange == nil, field.text != text {
            field.text = text
        }
        if isFocused, !field.isFirstResponder {
            field.becomeFirstResponder()
        }
    }

    func makeCoordinator() -> ShapeTextFieldAdapter { ShapeTextFieldAdapter() }
}

/// 系统输入框和正文规则之间的桥。测试可以直接驱动它，不经过可见点击。
final class ShapeTextFieldAdapter: NSObject, UITextFieldDelegate {
    var onCommit: (String) -> Void = { _ in }
    var onBegin: () -> Void = {}
    var onReturn: () -> Void = {}

    @objc func editingChanged(_ sender: UITextField) {
        guard sender.markedTextRange == nil else { return }
        onCommit(sender.text ?? "")
    }

    func textFieldDidBeginEditing(_ textField: UITextField) { onBegin() }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        onReturn()
        return false
    }

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        let marked = textField.markedTextRange != nil
        guard TextInputBridge.shouldInsert(replacement: string, hasMarkedText: marked) else {
            let proposed = TextInputBridge.replacing(textField.text ?? "", utf16Range: range, with: string)
            onCommit(proposed)
            return false
        }
        return true
    }
}
