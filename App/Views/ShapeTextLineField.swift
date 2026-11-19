import SwiftUI
import UIKit
import MosaicAppCore

/// 两行文字。焦点和组合标记留在这里，正文仍交给外面的模型。
struct ShapeTextLinesEditor: View {
    var lines: [String]
    var onCommit: (_ index: Int, _ text: String, _ secondLineIsComposing: Bool) -> Void
    @State private var focus: Int?
    @State private var marks = ShapeTextMarks()

    var body: some View {
        let normalized = TextDraftEditor.normalized(lines)
        return VStack(alignment: .leading, spacing: 8) {
            ShapeTextLineField(title: L10nKey.shapeTextLine1.localized, text: normalized[0], identifier: "shape-text-0",
                               isFocused: focus == 0,
                               onCommit: { onCommit(0, $0, marks.marked[1]) },
                               onMarked: { marks.marked[0] = $0 },
                               onBegin: { focus = 0 },
                               onReturn: { field in
                                   focus = 1
                                   // 回车处理还没结束时立刻抢焦点会被系统拉回第一行，所以放到下一轮。
                                   DispatchQueue.main.async {
                                       _ = field.window?.textField(identifier: "shape-text-1")?.becomeFirstResponder()
                                   }
                               })
            ShapeTextLineField(title: L10nKey.shapeTextLine2.localized, text: normalized[1], identifier: "shape-text-1",
                               isFocused: focus == 1,
                               onCommit: { onCommit(1, $0, false) },
                               onMarked: { marks.marked[1] = $0 },
                               onBegin: { focus = 1 },
                               onReturn: { field in
                                   focus = nil
                                   DispatchQueue.main.async {
                                       _ = field.resignFirstResponder()
                                   }
                               })
        }
    }
}

/// 组合标记要在提交的同一轮就能读到，不能等下一次界面刷新。
final class ShapeTextMarks {
    var marked = [false, false]
}

/// 一行文字。组合态留在系统输入框里；模型拒绝后把文字和光标拉回已提交正文，不重建控件。
struct ShapeTextLineField: UIViewRepresentable {
    var title: String
    var text: String
    var identifier: String
    var isFocused: Bool
    var onCommit: (String) -> Void
    var onMarked: (Bool) -> Void
    var onBegin: () -> Void
    var onReturn: (UITextField) -> Void

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
        adapter.onMarked = onMarked
        adapter.onBegin = onBegin
        adapter.onReturn = onReturn
        adapter.sync(modelText: text, focused: isFocused, field: field)
    }

    func makeCoordinator() -> ShapeTextFieldAdapter { ShapeTextFieldAdapter() }
}

/// 系统输入框和正文规则之间的桥。测试直接驱动它，不经过可见点击。
final class ShapeTextFieldAdapter: NSObject, UITextFieldDelegate {
    var onCommit: (String) -> Void = { _ in }
    var onMarked: (Bool) -> Void = { _ in }
    var onBegin: () -> Void = {}
    var onReturn: (UITextField) -> Void = { _ in }
    private var applyingModel = false

    /// 模型拒绝后把控件文本拉回，并把光标放在拉回后的正文里。组合中不动。
    func sync(modelText: String, focused: Bool, field: UITextField) {
        if focused, !field.isFirstResponder {
            field.becomeFirstResponder()
        }
        if field.markedTextRange == nil, field.text != modelText {
            applyingModel = true
            field.text = modelText
            // 整次拒绝后，光标停在拉回的正文末尾。不截断，也不另造一个输入框。
            placeCaret(field, utf16: (modelText as NSString).length)
            applyingModel = false
        }
        if !focused, field.isFirstResponder {
            field.resignFirstResponder()
        }
    }

    @objc func editingChanged(_ sender: UITextField) {
        onMarked(sender.markedTextRange != nil)
        if applyingModel { return }
        guard sender.markedTextRange == nil else { return }
        onCommit(sender.text ?? "")
    }

    func textFieldDidBeginEditing(_ textField: UITextField) { onBegin() }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        onReturn(textField)
        return false
    }

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        let marked = textField.markedTextRange != nil
        onMarked(marked)
        guard TextInputBridge.shouldInsert(replacement: string, hasMarkedText: marked) else {
            let proposed = TextInputBridge.replacing(textField.text ?? "", utf16Range: range, with: string)
            onCommit(proposed)
            return false
        }
        return true
    }

    func caretUTF16(_ field: UITextField) -> Int {
        guard let range = field.selectedTextRange else { return (field.text as NSString?)?.length ?? 0 }
        return field.offset(from: field.beginningOfDocument, to: range.start)
    }

    func placeCaret(_ field: UITextField, utf16: Int) {
        let length = (field.text as NSString?)?.length ?? 0
        let clamped = min(max(0, utf16), length)
        guard let position = field.position(from: field.beginningOfDocument, offset: clamped) else { return }
        field.selectedTextRange = field.textRange(from: position, to: position)
    }
}

private extension UIView {
    func textField(identifier: String) -> UITextField? {
        if let field = self as? UITextField, field.accessibilityIdentifier == identifier { return field }
        for child in subviews {
            if let found = child.textField(identifier: identifier) { return found }
        }
        return nil
    }
}
