/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import XCTest

class ScreenGraphTest: XCTestCase {
    var navigator: Navigator<TestUserState>!
    var app: XCUIApplication!

    override func setUp() {
        app = XCUIApplication()
        navigator = createTestGraph(app).navigator(self)
        restart(app, args: [LaunchArguments.ClearProfile, LaunchArguments.SkipIntro])
    }

    func restart(_ app: XCUIApplication, args: [String] = []) {
        XCUIDevice.shared().press(.home)
        var launchArguments = [LaunchArguments.Test]
        args.forEach { arg in
            launchArguments.append(arg)
        }
        app.launchArguments = launchArguments
        app.activate()
    }
}

extension ScreenGraphTest {
    func testUserStateChanges() {
        XCTAssertNil(navigator.userState.url, "Current url is empty")
        navigator.goto(BrowserTab)

        XCTAssertTrue(navigator.userState.url?.starts(with: "support.mozilla.org") ?? false, "Current url recorded by from the url bar")
    }
}

class TestUserState: UserState {
    required init() {
        super.init()
        initialScreenState = FirstRun
    }

    var url: String? = nil
}

func createTestGraph(_ app: XCUIApplication) -> ScreenGraph<TestUserState> {
    let map = ScreenGraph(with: TestUserState.self)

    map.addScreenState(FirstRun) { screenState in
        screenState.noop(to: BrowserTab)
    }

    map.addScreenState(BrowserTab) { screenState in
        screenState.onEnter("exists != true", element: app.progressIndicators.element(boundBy: 0)) { userState in
            userState.url = app.textFields["url"].value as? String
        }
    }

    return map
}
