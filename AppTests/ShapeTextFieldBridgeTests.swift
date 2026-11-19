import UIKit
import XCTest
import MosaicAppCore
@testable import PhotoMosaic

/// 系统输入框的组合态和换行粘贴。跑在 App 测试宿主里，驱动 `UITextField`，不是 XCUITest，也没有可见键盘点击。
/// `setMarkedText` 只证明标记区间还在时不提交；不能把它写成某次拼音输入已经在界面上完成。
final class ShapeTextFieldBridgeTests: XCTestCase {
    func testMarkedTextStaysUncommittedAndNewlinePasteSubmitsTheWholePair() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 80))
        let field = UITextField(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        window.addSubview(field)
        window.makeKeyAndVisible()
        field.text = "生日快乐"
        let adapter = ShapeTextFieldAdapter()
        var commits: [String] = []
        adapter.onCommit = { commits.append($0) }
        field.delegate = adapter
        field.addTarget(adapter, action: #selector(ShapeTextFieldAdapter.editingChanged(_:)), for: .editingChanged)
        XCTAssertTrue(field.becomeFirstResponder())

        field.setMarkedText("生", selectedRange: NSRange(location: 0, length: 1))
        field.sendActions(for: .editingChanged)
        XCTAssertNotNil(field.markedTextRange, "系统输入框没有进入组合态")
        XCTAssertTrue(commits.isEmpty, "组合态期间不能提交正文")

        field.unmarkText()
        commits.removeAll()
        field.text = ""
        let inserted = adapter.textField(field, shouldChangeCharactersIn: NSRange(location: 0, length: 0),
                                         replacementString: "生日快乐\n宝贝")
        XCTAssertFalse(inserted, "真实换行不交给单行控件插入")
        XCTAssertEqual(commits, ["生日快乐\n宝贝"])
        let pair = TextInputBridge.receive(lines: ["", ""], index: 0, fieldText: commits[0], hasMarkedText: false)
        XCTAssertEqual(pair.lines, ["生日快乐", "宝贝"])
        XCTAssertNil(pair.notice)
        let rejected = TextInputBridge.receive(lines: pair.lines, index: 0, fieldText: "生日快乐呀", hasMarkedText: false)
        XCTAssertEqual(rejected.lines, ["生日快乐", "宝贝"])
        XCTAssertEqual(rejected.notice, .lineTooLong(line: 0))
    }
}
