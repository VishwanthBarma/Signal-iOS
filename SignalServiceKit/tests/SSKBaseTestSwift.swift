//
//  Copyright (c) 2022 Open Whisper Systems. All rights reserved.
//

import XCTest
@testable import SignalServiceKit
import CocoaLumberjack

extension Thenable {
    func expect(timeout: TimeInterval, file: StaticString = #file, line: UInt = #line) -> Value {
        let expectation = XCTestExpectation(description: "\(file):\(line)")
        var result: Value?
        self.done {
            result = $0
            expectation.fulfill()
        }.catch {
            XCTFail("\($0)", file: file, line: line)
        }
        _ = XCTWaiter.wait(for: [expectation], timeout: timeout)
        return try! XCTUnwrap(result, file: file, line: line)
    }
}

@objc
public class SSKBaseTestSwift: XCTestCase {

    @objc
    public override func setUp() {
        super.setUp()

        DDLog.add(DDTTYLogger.sharedInstance!)

        ClearCurrentAppContextForTests()
        SetCurrentAppContext(TestAppContext())

        MockSSKEnvironment.activate()

        GroupManager.forceV1Groups()
    }

    @objc
    public override func tearDown() {
        AssertIsOnMainThread()

        // Spin the main run loop to flush any remaining async work.
        var done = false
        DispatchQueue.main.async { done = true }
        while !done {
            CFRunLoopRunInMode(.defaultMode, 0.0, true)
        }

        super.tearDown()
    }

    @objc
    public func read(_ block: (SDSAnyReadTransaction) -> Void) {
        return databaseStorage.read(block: block)
    }

    public func write<T>(_ block: (SDSAnyWriteTransaction) -> T) -> T {
        return databaseStorage.write(block: block)
    }

    @objc
    public func asyncWrite(_ block: @escaping (SDSAnyWriteTransaction) -> Void) {
        return databaseStorage.asyncWrite(block: block)
    }
}
