/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import XCTest

class ScreenGraphTest: XCTestCase {
    var navigator: Navigator<TestUserState>!
    var app: XCUIApplication!

    override func setUp() {
        app = XCUIApplication()
        navigator = createTestGraph(for: self, with: app).navigator()
        app.terminate()
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

    func testBackStack() {
        // We'll go through the browser tab, through the menu.
        navigator.goto(SettingsScreen)
        // Going back, there is no explicit way back to the browser tab,
        // and the menu will have dismissed. We should be detecting the existence of
        // elements as we go through each screen state, so if there are errors, they'll be
        // reported in the graph below.
        navigator.goto(BrowserTab)
    }

    func testSimpleToggleAction() {
        // Switch night mode on, by toggling.
        navigator.performAction(Action.ToggleNightMode)
        XCTAssertTrue(navigator.userState.nightMode)
        XCTAssertEqual(navigator.screenState, BrowserTab)

        // Nothing should happen here, because night mode is already on.
        navigator.toggleOn(navigator.userState.nightMode, withAction: Action.ToggleNightMode)
        XCTAssertTrue(navigator.userState.nightMode)
        XCTAssertEqual(navigator.screenState, BrowserTab)

        // Switch night mode off.
        navigator.toggleOff(navigator.userState.nightMode, withAction: Action.ToggleNightMode)
        XCTAssertFalse(navigator.userState.nightMode)
        XCTAssertEqual(navigator.screenState, BrowserTab)
    }

    func testChainedActionPerf1() {
        let navigator = self.navigator!
        measure {
            navigator.userState.url = defaultURL
            navigator.performAction(Action.LoadURLByPasting)
            XCTAssertEqual(navigator.screenState, BrowserTab)
        }
    }

    func testChainedActionPerf2() {
        let navigator = self.navigator!
        measure {
            navigator.userState.url = defaultURL
            navigator.performAction(Action.LoadURLByTyping)
            XCTAssertEqual(navigator.screenState, BrowserTab)
        }

        navigator.userState.url = defaultURL
        navigator.performAction(Action.LoadURL)
        XCTAssertEqual(navigator.screenState, BrowserTab)
    }
}


let defaultURL = "https://example.com"
class TestUserState: UserState {
    required init() {
        super.init()
        initialScreenState = FirstRun
    }

    var url: String? = nil
    var nightMode = false
}

fileprivate class Action {
    static let ToggleNightMode = "menu-NightMode"
    static let LoadURL = "LoadURL"
    static let LoadURLByTyping = "LoadURLByTyping"
    static let LoadURLByPasting = "LoadURLByPasting"
}

fileprivate func createTestGraph(for test: XCTestCase, with app: XCUIApplication) -> ScreenGraph<TestUserState> {
    let map = ScreenGraph(for: test, with: TestUserState.self)

    map.addScreenState(FirstRun) { screenState in
        screenState.noop(to: BrowserTab)
        screenState.tap(app.textFields["url"], to: URLBarOpen)
    }

    map.addScreenState(BrowserTab) { screenState in
        screenState.onEnter("exists != true", element: app.progressIndicators.element(boundBy: 0)) { userState in
            userState.url = app.textFields["url"].value as? String
        }

        screenState.tap(app.buttons["TabToolbar.menuButton"], to: BrowserTabMenu)
        screenState.tap(app.textFields["url"], to: URLBarOpen)

        screenState.gesture(forAction: Action.LoadURLByPasting, Action.LoadURL) { userState in
            UIPasteboard.general.string = userState.url ?? defaultURL
            app.textFields["url"].press(forDuration: 1.0)
            app.sheets.element(boundBy: 0).buttons.element(boundBy: 0).tap()
        }
    }

    map.addScreenState(URLBarOpen) { screenState in
        screenState.gesture(forAction: Action.LoadURLByTyping, Action.LoadURL) { userState in
            let urlString = userState.url ?? defaultURL
            app.textFields["address"].typeText("\(urlString)\r")
        }
    }

    map.addScreenAction(Action.LoadURL, transitionTo: BrowserTab) { userState in
        // NOP
    }

    map.addScreenState(BrowserTabMenu) { screenState in
        screenState.dismissOnUse = true
        screenState.onEnter(element: app.tables["Context Menu"])
        screenState.tap(app.tables.cells["Settings"], to: SettingsScreen)

        screenState.tap(app.cells["menu-NightMode"], forAction: Action.ToggleNightMode) { userState in
            userState.nightMode = !userState.nightMode
        }

        screenState.backAction = {
            app.buttons["PhotonMenu.cancel"].tap()
        }
    }

    let navigationControllerBackAction = {
        app.navigationBars.element(boundBy: 0).buttons.element(boundBy: 0).tap()
    }

    map.addScreenState(SettingsScreen) { screenState in
        screenState.backAction = navigationControllerBackAction
    }

    return map
}
