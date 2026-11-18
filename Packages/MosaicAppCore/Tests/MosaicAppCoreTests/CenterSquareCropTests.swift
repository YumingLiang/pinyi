import XCTest
@testable import MosaicAppCore

final class CenterSquareCropTests: XCTestCase {
    func testPortrait() {
        // 256×341：短边 256，竖向居中，余量 85 → 上 42、下 43。
        let r = CenterSquareCrop.rect(width: 256, height: 341)
        XCTAssertEqual(r.x, 0)
        XCTAssertEqual(r.y, 42)
        XCTAssertEqual(r.size, 256)
        XCTAssertEqual(r.y + r.size, 298)
        XCTAssertEqual(341 - (r.y + r.size), 43)
        XCTAssertEqual(CenterSquareCrop.outputSide(sourceWidth: 256, sourceHeight: 341, maxEdge: 256), 256)
    }

    func testLandscape() {
        let r = CenterSquareCrop.rect(width: 341, height: 256)
        XCTAssertEqual(r.x, 42)
        XCTAssertEqual(r.y, 0)
        XCTAssertEqual(r.size, 256)
        XCTAssertEqual(CenterSquareCrop.outputSide(sourceWidth: 341, sourceHeight: 256, maxEdge: 256), 256)
    }

    func testSquareUnchanged() {
        let r = CenterSquareCrop.rect(width: 256, height: 256)
        XCTAssertEqual(r.x, 0)
        XCTAssertEqual(r.y, 0)
        XCTAssertEqual(r.size, 256)
        XCTAssertEqual(CenterSquareCrop.outputSide(sourceWidth: 256, sourceHeight: 256, maxEdge: 256), 256)
    }

    func testOddSizesCenterFloor() {
        // 255×341：短边 255，余量 86 → 上下各 43。
        let portrait = CenterSquareCrop.rect(width: 255, height: 341)
        XCTAssertEqual(portrait.x, 0)
        XCTAssertEqual(portrait.y, 43)
        XCTAssertEqual(portrait.size, 255)
        XCTAssertEqual(portrait.y + portrait.size + 43, 341)

        // 341×255
        let landscape = CenterSquareCrop.rect(width: 341, height: 255)
        XCTAssertEqual(landscape.x, 43)
        XCTAssertEqual(landscape.y, 0)
        XCTAssertEqual(landscape.size, 255)

        // 两边都是奇数、差为奇数：5×10，余量 5 → 上 2、下 3。
        let odd = CenterSquareCrop.rect(width: 5, height: 10)
        XCTAssertEqual(odd.x, 0)
        XCTAssertEqual(odd.y, 2)
        XCTAssertEqual(odd.size, 5)
        XCTAssertEqual(10 - (odd.y + odd.size), 3)
    }

    func testShortSideSmallerThanTargetKeepsNativeSquare() {
        // 100×150 裁成 100×100，目标 256 时不放大。
        let r = CenterSquareCrop.rect(width: 100, height: 150)
        XCTAssertEqual(r.x, 0)
        XCTAssertEqual(r.y, 25)
        XCTAssertEqual(r.size, 100)
        XCTAssertEqual(CenterSquareCrop.outputSide(sourceWidth: 100, sourceHeight: 150, maxEdge: 256), 100)
        XCTAssertEqual(CenterSquareCrop.outputSide(sourceWidth: 150, sourceHeight: 100, maxEdge: 256), 100)
        // 旧写法按长边缩到 256 会得到 192×256，这里必须避免。
        XCTAssertEqual(CenterSquareCrop.outputSide(sourceWidth: 256, sourceHeight: 341, maxEdge: 256), 256)
    }

    func testLargerThanTargetScalesDownToMaxEdge() {
        XCTAssertEqual(CenterSquareCrop.outputSide(sourceWidth: 512, sourceHeight: 768, maxEdge: 256), 256)
        let r = CenterSquareCrop.rect(width: 512, height: 768)
        XCTAssertEqual(r.x, 0)
        XCTAssertEqual(r.y, 128)
        XCTAssertEqual(r.size, 512)
    }

    func testInvalidInputs() {
        XCTAssertEqual(CenterSquareCrop.rect(width: 0, height: 10).size, 0)
        XCTAssertEqual(CenterSquareCrop.rect(width: 10, height: 0).size, 0)
        XCTAssertEqual(CenterSquareCrop.rect(width: -4, height: 10).size, 0)
        XCTAssertEqual(CenterSquareCrop.outputSide(sourceWidth: 0, sourceHeight: 10, maxEdge: 256), 0)
        XCTAssertEqual(CenterSquareCrop.outputSide(sourceWidth: 100, sourceHeight: 100, maxEdge: 0), 100)
        XCTAssertEqual(CenterSquareCrop.outputSide(sourceWidth: 100, sourceHeight: 100, maxEdge: -8), 100)
    }
}
