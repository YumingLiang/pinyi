import SwiftUI
import UIKit
import XCTest
import MosaicAppCore
@testable import PhotoMosaic

/// 把生产用的两行输入放进测试宿主，驱动 `UITextField`。不是 XCUITest，也没有可见键盘点击。
/// 组合结束留下的 `commits` 不能清掉。本文件在没有 Apple SDK 的环境不会执行。
@MainActor
final class ShapeTextFieldBridgeTests: XCTestCase {
    func testUnmarkKeepsTheEndedCommitAndCancelRestoresTheLine() {
        let rig = mount(lines: ["生日快乐", ""])
        let field = rig.line(0)
        let same = field
        XCTAssertTrue(field.becomeFirstResponder())
        field.delegate?.textFieldDidBeginEditing?(field)
        placeCaretAtEnd(field)
        field.setMarkedText("生", selectedRange: NSRange(location: 0, length: 1))
        field.sendActions(for: .editingChanged)
        XCTAssertNotNil(field.markedTextRange, "系统输入框没有进入组合态")
        XCTAssertTrue(rig.store.commits.isEmpty, "组合期间不能提交")

        let before = rig.store.commits.count
        field.unmarkText()
        if rig.store.commits.count == before {
            field.sendActions(for: .editingChanged)
        }
        XCTAssertGreaterThan(rig.store.commits.count, before, "组合结束必须留下提交")
        let ended = rig.store.commits[rig.store.commits.count - 1]
        XCTAssertEqual(ended.index, 0)
        XCTAssertFalse(ended.text.isEmpty)
        XCTAssertNil(field.markedTextRange)
        pump()
        if rig.store.notice != nil {
            XCTAssertEqual(rig.store.lines, ["生日快乐", ""])
            XCTAssertEqual(field.text, "生日快乐")
        } else {
            XCTAssertEqual(field.text, ended.text)
            XCTAssertEqual(rig.store.lines[0], ended.text)
        }
        XCTAssertEqual(rig.store.commits.last?.text, ended.text, "不能清掉组合结束的提交")
        XCTAssertTrue(field === same, "回滚不能换掉控件")

        let restored = field.text ?? ""
        placeCaretAtEnd(field)
        field.setMarkedText("呀", selectedRange: NSRange(location: 0, length: 1))
        field.sendActions(for: .editingChanged)
        XCTAssertNotNil(field.markedTextRange)
        guard let marked = field.markedTextRange else { return XCTFail("取消前没有组合区间") }
        field.replace(marked, withText: "")
        if field.markedTextRange != nil {
            field.sendActions(for: .editingChanged)
        } else if rig.store.commits.last?.text != restored {
            field.sendActions(for: .editingChanged)
        }
        pump()
        XCTAssertNil(field.markedTextRange)
        XCTAssertEqual(field.text, restored, "取消组合后控件应回到取消前的正文")
        XCTAssertEqual(rig.store.lines[0], restored)
        XCTAssertTrue(field === same)
    }

    func testRejectedOverlongAndEmojiRollBackTextCaretAndKeepFocus() {
        let rig = mount(lines: ["生日快乐", ""])
        let field = rig.line(0)
        XCTAssertTrue(field.becomeFirstResponder())
        field.delegate?.textFieldDidBeginEditing?(field)
        pump()
        field.text = "生日快乐呀"
        field.sendActions(for: .editingChanged)
        pump()
        XCTAssertEqual(rig.store.commits.last?.text, "生日快乐呀")
        XCTAssertEqual(rig.store.notice, .lineTooLong(line: 0))
        XCTAssertEqual(rig.store.lines[0], "生日快乐")
        XCTAssertEqual(field.text, rig.store.lines[0])
        XCTAssertTrue(field.isFirstResponder)
        XCTAssertNotNil(field.selectedTextRange)
        XCTAssertEqual((rig.line(0).delegate as? ShapeTextFieldAdapter)?.caretUTF16(field),
                       ("生日快乐" as NSString).length)

        field.text = "生日😀"
        field.sendActions(for: .editingChanged)
        pump()
        XCTAssertEqual(rig.store.commits.last?.text, "生日😀")
        XCTAssertEqual(rig.store.notice, .unsupported)
        XCTAssertEqual(field.text, "生日快乐")
        XCTAssertEqual(field.text, rig.store.lines[0])
        XCTAssertTrue(field.isFirstResponder)
        XCTAssertTrue(field === rig.line(0))
    }

    func testReturnMovesFocusAndSecondReturnResigns() {
        let rig = mount(lines: ["生日快乐", "宝贝"])
        let first = rig.line(0)
        let second = rig.line(1)
        XCTAssertTrue(first.becomeFirstResponder())
        first.delegate?.textFieldDidBeginEditing?(first)
        pump()
        let firstAdapter = first.delegate as? ShapeTextFieldAdapter
        XCTAssertEqual(firstAdapter?.textFieldShouldReturn(first), false)
        pump()
        XCTAssertTrue(second.isFirstResponder, "第一行回车应让第二行成为焦点")
        XCTAssertFalse(first.isFirstResponder)
        let secondAdapter = second.delegate as? ShapeTextFieldAdapter
        XCTAssertEqual(secondAdapter?.textFieldShouldReturn(second), false)
        pump()
        XCTAssertFalse(second.isFirstResponder, "第二行回车应结束编辑")
        XCTAssertFalse(first.isFirstResponder)
        XCTAssertEqual(first.text, "生日快乐")
        XCTAssertEqual(second.text, "宝贝")
    }

    func testNewlinePasteFillsEmptySecondLineButKeepsEditedOrMarkedText() {
        let empty = mount(lines: ["", ""])
        let emptyField = empty.line(0)
        let inserted = (emptyField.delegate as? ShapeTextFieldAdapter)?.textField(
            emptyField, shouldChangeCharactersIn: NSRange(location: 0, length: 0),
            replacementString: "生日快乐\n宝贝")
        XCTAssertEqual(inserted, false)
        pump()
        XCTAssertEqual(empty.store.commits.last?.text, "生日快乐\n宝贝")
        XCTAssertEqual(empty.store.lines, ["生日快乐", "宝贝"])
        XCTAssertNil(empty.store.notice)
        XCTAssertEqual(empty.line(0).text, "生日快乐")
        XCTAssertEqual(empty.line(1).text, "宝贝")

        let rig = mount(lines: ["生日", "宝贝"])
        let first = rig.line(0)
        let second = rig.line(1)
        let length = (first.text as NSString?)?.length ?? 0
        let overwritten = (first.delegate as? ShapeTextFieldAdapter)?.textField(
            first, shouldChangeCharactersIn: NSRange(location: 0, length: length),
            replacementString: "生日快乐\n其他")
        XCTAssertEqual(overwritten, false)
        pump()
        XCTAssertEqual(rig.store.commits.last?.text, "生日快乐\n其他")
        XCTAssertEqual(rig.store.notice, .secondLineKept)
        XCTAssertEqual(rig.store.lines, ["生日", "宝贝"])
        XCTAssertEqual(first.text, "生日")
        XCTAssertEqual(second.text, "宝贝")

        XCTAssertTrue(second.becomeFirstResponder())
        second.delegate?.textFieldDidBeginEditing?(second)
        placeCaretAtEnd(second)
        second.setMarkedText("宝", selectedRange: NSRange(location: 0, length: 1))
        second.sendActions(for: .editingChanged)
        XCTAssertNotNil(second.markedTextRange)
        let markedText = second.text
        let duringMark = (first.delegate as? ShapeTextFieldAdapter)?.textField(
            first, shouldChangeCharactersIn: NSRange(location: 0, length: (first.text as NSString?)?.length ?? 0),
            replacementString: "生日快乐\n宝贝")
        XCTAssertEqual(duringMark, false)
        pump()
        XCTAssertNotNil(second.markedTextRange, "第二行组合中，第一行换行不能拆掉标记")
        XCTAssertEqual(second.text, markedText)
        XCTAssertEqual(rig.store.lines[1], "宝贝")
        XCTAssertEqual(first.text, "生日")
    }

    private func mount(lines: [String]) -> Rig {
        let store = TextHostStore(lines: lines)
        let host = UIHostingController(rootView: TextHostView(store: store))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        pump()
        let fields = host.view.textFields()
        let first = fields.first { $0.accessibilityIdentifier == "shape-text-0" }
        let second = fields.first { $0.accessibilityIdentifier == "shape-text-1" }
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        return Rig(store: store, window: window, fields: [first!, second!])
    }

    private func pump() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    private func placeCaretAtEnd(_ field: UITextField) {
        let end = field.endOfDocument
        field.selectedTextRange = field.textRange(from: end, to: end)
    }
}

private struct Rig {
    let store: TextHostStore
    let window: UIWindow
    let fields: [UITextField]
    func line(_ index: Int) -> UITextField { fields[index] }
}

private final class TextHostStore: ObservableObject {
    @Published var lines: [String]
    @Published var notice: TextInputNotice?
    var commits: [(index: Int, text: String)] = []

    init(lines: [String]) { self.lines = lines }

    func commit(_ index: Int, _ text: String, secondLineIsComposing: Bool) {
        commits.append((index, text))
        let outcome = TextInputBridge.receive(lines: lines, index: index, fieldText: text,
                                              hasMarkedText: false, secondLineIsComposing: secondLineIsComposing)
        guard !outcome.composing else { return }
        lines = outcome.lines
        notice = outcome.notice
    }
}

private struct TextHostView: View {
    @ObservedObject var store: TextHostStore
    var body: some View {
        ShapeTextLinesEditor(lines: store.lines) { index, text, second in
            store.commit(index, text, secondLineIsComposing: second)
        }
    }
}

private extension UIView {
    func textFields() -> [UITextField] {
        var found: [UITextField] = []
        if let field = self as? UITextField { found.append(field) }
        for child in subviews { found.append(contentsOf: child.textFields()) }
        return found
    }
}
