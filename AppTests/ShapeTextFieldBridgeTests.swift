import SwiftUI
import UIKit
import XCTest
import MosaicAppCore
@testable import PhotoMosaic

/// 把生产用的两行输入放进测试宿主，驱动 `UITextField`。不是 XCUITest，也没有可见键盘。
/// `unmarkText` 若没有自己发出 `editingChanged`，测试会手工 `sendActions(.editingChanged)`。
/// 那条提交的断言仍要求确定全文；手工事件不能写成自然结束或键盘已验证。
/// 本文件在没有 Apple SDK 的环境不会执行。
@MainActor
final class ShapeTextFieldBridgeTests: XCTestCase {
    func testUnmarkKeepsTheEndedCommitAndCancelRestoresTheLine() {
        let legal = "生日"
        let rig = mount(lines: ["", ""])
        let field = rig.line(0)
        let same = field
        XCTAssertTrue(field.becomeFirstResponder())
        field.delegate?.textFieldDidBeginEditing?(field)
        placeCaretAtEnd(field)
        field.setMarkedText(legal, selectedRange: NSRange(location: (legal as NSString).length, length: 0))
        field.sendActions(for: .editingChanged)
        XCTAssertNotNil(field.markedTextRange, "系统输入框没有进入组合态")
        XCTAssertTrue(rig.store.commits.isEmpty, "组合期间不能提交")

        let before = rig.store.commits.count
        field.unmarkText()
        XCTAssertNil(field.markedTextRange, "unmarkText 后不应仍有组合区间")
        XCTAssertEqual(field.text, legal, "unmarkText 后控件全文必须是确定的「生日」")
        let naturalUnmarkCommit = rig.store.commits.count == before + 1
        if !naturalUnmarkCommit {
            XCTAssertEqual(rig.store.commits.count, before, "unmarkText 没有自然提交时，不应已有别的提交")
            // 边界：这条 editingChanged 是测试手工发出的，不是 unmarkText 的自然通知，也不是键盘。
            field.sendActions(for: .editingChanged)
        }
        let driver = naturalUnmarkCommit
            ? "unmarkText 自己发出了 editingChanged。这不是键盘。"
            : "unmarkText 没有发出 editingChanged。提交由测试 sendActions(.editingChanged) 驱动，不是自然结束，也不是键盘。"
        XCTAssertEqual(rig.store.commits.count, before + 1, driver)
        XCTAssertEqual(rig.store.commits.last?.index, 0, driver)
        XCTAssertEqual(rig.store.commits.last?.text, legal, driver)
        pump()
        XCTAssertNil(rig.store.notice, "合法的「生日」不能被拒绝。\(driver)")
        XCTAssertEqual(rig.store.lines, [legal, ""], driver)
        XCTAssertEqual(field.text, legal, driver)
        XCTAssertTrue(field === same)

        placeCaretAtEnd(field)
        field.setMarkedText("呀", selectedRange: NSRange(location: 1, length: 0))
        field.sendActions(for: .editingChanged)
        XCTAssertNotNil(field.markedTextRange)
        XCTAssertEqual(rig.store.commits.count, before + 1, "取消前的组合不能提交")
        guard let marked = field.markedTextRange else { return XCTFail("取消前没有组合区间") }
        let beforeCancel = rig.store.commits.count
        field.replace(marked, withText: "")
        XCTAssertNil(field.markedTextRange, "取消后不应仍有组合区间")
        XCTAssertEqual(field.text, legal, "取消后控件应仍是「生日」")
        let naturalCancelCommit = rig.store.commits.count == beforeCancel + 1
        if !naturalCancelCommit {
            XCTAssertEqual(rig.store.commits.count, beforeCancel)
            // 边界：同样只是测试手工 editingChanged，不是 replace 的自然通知，也不是键盘。
            field.sendActions(for: .editingChanged)
        }
        let cancelDriver = naturalCancelCommit
            ? "replace 空文本自己发出了 editingChanged。这不是键盘。"
            : "replace 没有发出 editingChanged。提交由测试 sendActions(.editingChanged) 驱动，不是自然结束，也不是键盘。"
        XCTAssertEqual(rig.store.commits.last?.text, legal, cancelDriver)
        XCTAssertEqual(field.text, legal, cancelDriver)
        XCTAssertEqual(rig.store.lines, [legal, ""], cancelDriver)
        XCTAssertNil(rig.store.notice, cancelDriver)
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
        pump()
        XCTAssertFalse(second.isFirstResponder, "结束后再转一圈也不能把焦点拉回第二行")
        XCTAssertFalse(first.isFirstResponder)
        XCTAssertEqual(first.text, "生日快乐")
        XCTAssertEqual(second.text, "宝贝")
    }

    /// 第一次回车的移交还没执行，第二次回车已经要求结束。只能留下后一次。
    /// 直接调用代理，不是可见键盘。
    func testLaterReturnOverridesAnUnappliedHandoff() {
        let rig = mount(lines: ["生日快乐", "宝贝"])
        let first = rig.line(0)
        let second = rig.line(1)
        XCTAssertTrue(first.becomeFirstResponder())
        first.delegate?.textFieldDidBeginEditing?(first)
        pump()
        XCTAssertEqual((first.delegate as? ShapeTextFieldAdapter)?.textFieldShouldReturn(first), false)
        XCTAssertEqual((second.delegate as? ShapeTextFieldAdapter)?.textFieldShouldReturn(second), false)
        pump()
        XCTAssertFalse(first.isFirstResponder)
        XCTAssertFalse(second.isFirstResponder, "后一次回车必须盖过还没执行的焦点移交")
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

        // 第二行已经是同一段「宝贝」：允许粘贴。第二行字符串不变，第一行更新。这是幂等，不是拒绝。
        let same = mount(lines: ["生日", "宝贝"])
        let sameField = same.line(0)
        let sameLength = (sameField.text as NSString?)?.length ?? 0
        let samePaste = (sameField.delegate as? ShapeTextFieldAdapter)?.textField(
            sameField, shouldChangeCharactersIn: NSRange(location: 0, length: sameLength),
            replacementString: "生日快乐\n宝贝")
        XCTAssertEqual(samePaste, false)
        pump()
        XCTAssertEqual(same.store.commits.last?.text, "生日快乐\n宝贝")
        XCTAssertNil(same.store.notice)
        XCTAssertEqual(same.store.lines, ["生日快乐", "宝贝"])
        XCTAssertEqual(same.line(0).text, "生日快乐")
        XCTAssertEqual(same.line(1).text, "宝贝")

        // 本行仍在组合时，换行不在这一刻提交。组合结束后用整段替换再校验。
        let pending = mount(lines: ["", ""])
        let pendingField = pending.line(0)
        XCTAssertTrue(pendingField.becomeFirstResponder())
        placeCaretAtEnd(pendingField)
        pendingField.setMarkedText("日", selectedRange: NSRange(location: 1, length: 0))
        pendingField.sendActions(for: .editingChanged)
        XCTAssertNotNil(pendingField.markedTextRange)
        let during = pending.store.commits.count
        let held = (pendingField.delegate as? ShapeTextFieldAdapter)?.textField(
            pendingField, shouldChangeCharactersIn: NSRange(location: 0, length: 0),
            replacementString: "生日快乐\n宝贝")
        XCTAssertEqual(held, true, "组合中的换行应留给结束时整段校验，而不是现在提交")
        XCTAssertEqual(pending.store.commits.count, during, "组合中的换行不能产生提交")
        pendingField.unmarkText()
        XCTAssertNil(pendingField.markedTextRange)
        let beforeWhole = pending.store.commits.count
        // 边界：模拟器把 UITextField.text =「生日快乐\n宝贝」收成「生日快乐 宝贝」，再按不支持字符拒绝。
        // 换行只留在 shouldChangeCharactersIn 的 replacementString。组合已经结束。
        // 这次是测试直接调用代理，不是键盘，也不是 unmarkText 自己插入的换行。
        let wholeLength = (pendingField.text as NSString?)?.length ?? 0
        let finished = (pendingField.delegate as? ShapeTextFieldAdapter)?.textField(
            pendingField,
            shouldChangeCharactersIn: NSRange(location: 0, length: wholeLength),
            replacementString: "生日快乐\n宝贝")
        XCTAssertEqual(finished, false)
        XCTAssertEqual(pending.store.commits.count, beforeWhole + 1)
        XCTAssertEqual(pending.store.commits.last?.text, "生日快乐\n宝贝")
        pump()
        XCTAssertNil(pending.store.notice, "结束后的合法两行不能被拒绝")
        XCTAssertEqual(pending.store.lines, ["生日快乐", "宝贝"])
        XCTAssertEqual(pending.line(0).text, "生日快乐")
        XCTAssertEqual(pending.line(1).text, "宝贝")
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
