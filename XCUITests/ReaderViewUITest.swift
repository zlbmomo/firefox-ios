/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import XCTest

class ReaderViewTest: BaseTestCase {
    var navigator: Navigator!
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        app = XCUIApplication()
        navigator = createScreenGraph(app).navigator(self)
    }

    override func tearDown() {
        super.tearDown()
    }

    func testLoadReaderContent() {
        navigator.goto(BrowserTab)
        app.buttons["Reader View"].tap()
        // The settings of reader view are shown as well as the content of the web site
        waitforExistence(app.buttons["Display Settings"])
        XCTAssertTrue(app.webViews.staticTexts["The Book of Mozilla"].exists)
    }

    private func addContentToReaderView() {
        navigator.goto(BrowserTab)
        waitUntilPageLoad()
        app.buttons["Reader View"].tap()
        waitforExistence(app.buttons["Add to Reading List"])
        app.buttons["Add to Reading List"].tap()
    }

    private func checkReadingListNumberOfItems(items: Int) {
        waitforExistence(app.tables["ReadingTable"])
        let list = app.tables["ReadingTable"].cells.count
        XCTAssertEqual(list, UInt(items), "The number of items in the reading table is not correct")
    }

    func testAddToReadingList() {
        // Initially reading list is empty
        navigator.goto(HomePanel_ReadingList)

        // Check the button is selected (is disabled and the rest bookmarks and so are enabled)
        XCTAssertFalse(app.buttons["HomePanels.ReadingList"].isEnabled)
        XCTAssertTrue(app.buttons["HomePanels.Bookmarks"].isEnabled)

        checkReadingListNumberOfItems(items: 0)

        // Add item to reading list and check that it appears
        addContentToReaderView()
        navigator.goto(HomePanel_ReadingList)
        waitforExistence(app.buttons["HomePanels.ReadingList"])

        // Check that there is one item
        let savedToReadingList = app.tables["ReadingTable"].cells.staticTexts["The Book of Mozilla"]
        XCTAssertTrue(savedToReadingList.exists)
        checkReadingListNumberOfItems(items: 1)
    }

    func testMarkAsReadAndUreadFromReaderView() {
        addContentToReaderView()

        // Mark the content as read, so the mark as unread buttons appear
        app.buttons["Mark as Read"].tap()
        waitforExistence(app.buttons["Mark as Unread"])

        // Mark the content as unread, so the mark as read button appear
        app.buttons["Mark as Unread"].tap()
        waitforExistence(app.buttons["Mark as Read"])
    }

    func testRemoveFromReadingView() {
        addContentToReaderView()
        // Once the content has been added, remove it
        waitforExistence(app.buttons["Remove from Reading List"])
        app.buttons["Remove from Reading List"].tap()

        // Check that instead of the remove icon now it is shown the add to read list
        waitforExistence(app.buttons["Add to Reading List"])

        // Go to reader list view to check that there is not any item there
        navigator.goto(HomePanel_ReadingList)
        waitforExistence(app.buttons["HomePanels.ReadingList"])
        navigator.goto(HomePanel_ReadingList)
        checkReadingListNumberOfItems(items: 0)
    }

    func testMarkAsReadAndUnreadFromReadingList() {
        addContentToReaderView()
        navigator.goto(HomePanel_ReadingList)
        waitforExistence(app.buttons["HomePanels.ReadingList"])
        navigator.goto(HomePanel_ReadingList)

        // Check that there is one item
        let savedToReadingList = app.tables["ReadingTable"].cells.staticTexts["The Book of Mozilla"]
        XCTAssertTrue(savedToReadingList.exists)

        // Mark it as read/unread
        savedToReadingList.swipeLeft()
        waitforExistence(app.buttons["Mark as  Read"])
        app.buttons["Mark as  Read"].tap()
        savedToReadingList.swipeLeft()
        waitforExistence(app.buttons["Mark as  Unread"])
    }

    func testRemoveFromReadingList() {
        addContentToReaderView()
        navigator.goto(HomePanel_ReadingList)
        waitforExistence(app.buttons["HomePanels.ReadingList"])
        navigator.goto(HomePanel_ReadingList)

        let savedToReadingList = app.tables["ReadingTable"].cells.staticTexts["The Book of Mozilla"]
        savedToReadingList.swipeLeft()
        waitforExistence(app.buttons["Remove"])

        // Remove the item from reading list
        app.buttons["Remove"].tap()
        XCTAssertFalse(savedToReadingList.exists)

        // Reader list view should be empty
        checkReadingListNumberOfItems(items: 0)
    }

    func testAddToReadingListFromPageOptionsMenu() {
        // First time Reading list is empty
        navigator.goto(HomePanel_ReadingList)
        checkReadingListNumberOfItems(items: 0)

        // Add item to Reading List from Page Options Menu
        navigator.goto(BrowserTab)
        waitUntilPageLoad()
        navigator.browserPerformAction(.addReadingListOption)

        // Now there should be an item on the list
        navigator.nowAt(BrowserTab)
        navigator.browserPerformAction(.openReadingListOption)
        checkReadingListNumberOfItems(items: 1)
    }
}
