import Foundation
import XCTest
@testable import Sash

final class ObjCExceptionsTests: XCTestCase {
    func testRaisedExceptionBecomesThrownError() {
        XCTAssertThrowsError(try withObjCExceptionsCaught {
            NSException(name: .invalidArgumentException, reason: "boom", userInfo: nil).raise()
        }) { error in
            guard let e = error as? Sash.ObjCException else { return XCTFail("wrong error \(error)") }
            XCTAssertEqual(e.name, NSExceptionName.invalidArgumentException.rawValue)
            XCTAssertEqual(e.reason, "boom")
        }
    }

    func testValueAndSwiftErrorsPassThrough() throws {
        XCTAssertEqual(try withObjCExceptionsCaught { 42 }, 42)
        struct E: Error {}
        XCTAssertThrowsError(try withObjCExceptionsCaught { throw E() }) { XCTAssertTrue($0 is E) }
    }
}
