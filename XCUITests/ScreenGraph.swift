/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

/**
 * ScreenGraph helps you get rid of the navigation boiler plate found in a lot of whole-application UI testing.
 *
 * You create a shared graph of UI 'screens' or 'scenes' for your app, and use it for every test.
 *
 * In your tests, you use a navigator which does the job of getting your tests from place to place in your application,
 * leaving you to concentrate on testing, rather than maintaining brittle and duplicated navigation code.
 * 
 * The shared graph may also have other uses, such as generating screen shots for the App Store or L10n translators.
 *
 * Under the hood, the ScreenGraph is using GameplayKit's path finding to do the heavy lifting.
 */

import Foundation
import GameplayKit
import XCTest

struct Edge {
    let transition: (XCTestCase, String, UInt) -> Void
}

typealias SceneBuilder<T: UserState> = (ScreenStateNode<T>) -> Void
typealias NodeVisitor = (String) -> Void

open class UserState {
    public required init() {}
    var initialScreenState: String?
}

/**
 * ScreenGraph
 * This is the main interface to building a graph of screens/app states and how to navigate between them.
 * The ScreenGraph will be used as a map to navigate the test agent around the app.
 */
open class ScreenGraph<T: UserState> {
    fileprivate let userStateType: T.Type
    fileprivate let xcTest: XCTestCase

    fileprivate var namedScenes: [String: GraphNode<T>] = [:]
    fileprivate var nodedScenes: [GKGraphNode: GraphNode<T>] = [:]

    fileprivate var isReady: Bool = false

    fileprivate let gkGraph: GKGraph

    typealias UserStateChange = (T) -> ()

    init(for test: XCTestCase, with userStateType: T.Type) {
        self.gkGraph = GKGraph()
        self.userStateType = userStateType
        self.xcTest = test
    }
}

extension ScreenGraph {
    /**
     * Method for creating a ScreenGraphNode in the graph. The node should be accompanied by a closure 
     * used to document the exits out of this node to other nodes.
     */
    func createScene(_ name: String, file: String = #file, line: UInt = #line, builder: @escaping SceneBuilder<T>) {
        addScreenState(name, file: file, line: line, builder: builder)
    }

    func addScreenState(_ name: String, file: String = #file, line: UInt = #line, builder: @escaping SceneBuilder<T>) {
        let scene = ScreenStateNode(map: self, name: name, file: file, line: line, builder: builder)
        namedScenes[name] = scene
    }

    func addScreenAction(_ name: String, transitionTo nextNodeName: String, file: String = #file, line: UInt = #line, recorder: @escaping (T) -> ()) {
        addOrCheckScreenAction(name, transitionTo: nextNodeName, file: file, line: line, recorder: recorder)
    }
}

extension ScreenGraph {
    fileprivate func addActionChain(_ actions: [String], finalState screenState: String?, r: @escaping UserStateChange, file: String, line: UInt) {
        for i in 0..<actions.count {
            let thisNodeName = actions[i]
            let nextNodeName = i+1 < actions.count ? actions[i+1] : screenState
            let recorder: UserStateChange?
            if i == 0 {
                recorder = r
            } else {
                recorder = nil
            }
            addOrCheckScreenAction(thisNodeName, transitionTo: nextNodeName, file: file, line: line, recorder: recorder)
        }
    }

    fileprivate func addOrCheckScreenAction(_ name: String, transitionTo nextNodeName: String? = nil, file: String = #file, line: UInt = #line, recorder: UserStateChange?) {
        let actionNode: ScreenActionNode<T>
        if let existingNode = namedScenes[name] {
            guard let existing = existingNode as? ScreenActionNode else {
                self.xcTest.recordFailure(withDescription: "Screen state \(name) conflicts with an identically named action", inFile: existingNode.file, atLine: existingNode.line, expected: false)
                self.xcTest.recordFailure(withDescription: "Action \(name) conflicts with an identically named screen state", inFile: file, atLine: line, expected: false)
                return
            }
            // The new node has to have the same nextNodeName as the existing node.
            // unless either one of them is nil, so use whichever is the non nil one.
            if let d1 = existing.nextNodeName,
                let d2 = nextNodeName,
                d1 != d2 {
                self.xcTest.recordFailure(withDescription: "Action points to \(d2) elsewhere", inFile: existing.file, atLine: existing.line, expected: false)
                self.xcTest.recordFailure(withDescription: "Action points to \(d1) elsewhere", inFile: file, atLine: line, expected: false)
                return
            }

            let overwriteNodeName = existing.nextNodeName ?? nextNodeName

            // The new version of the same node can have additional UserStateChange recorders,
            // so we just combine these together.
            let overwriteRecorder: UserStateChange?
            if let r1 = existing.recorder,
                let r2 = recorder {
                overwriteRecorder = { userState in
                    r1(userState)
                    r2(userState)
                }
            } else {
                overwriteRecorder = existing.recorder ?? recorder
            }

            actionNode = ScreenActionNode(self,
                                          name: name,
                                          then: overwriteNodeName,
                                          file: file,
                                          line: line,
                                          recorder: overwriteRecorder)

        } else {
            actionNode = ScreenActionNode(self,
                                          name: name,
                                          then: nextNodeName,
                                          file: file,
                                          line: line,
                                          recorder: recorder)
        }

        self.namedScenes[name] = actionNode
    }
}

extension ScreenGraph {
    /**
     * Create a new navigator object. Navigator objects are the main way of getting around the app.
     * Typically, you'll do this in `TestCase.setUp()`
     */
    func navigator(startingAt: String? = nil, file: String = #file, line: UInt = #line) -> Navigator<T> {
        buildGkGraph()
        var current: ScreenStateNode<T>?
        let userState = userStateType.init()
        if let name = startingAt ?? userState.initialScreenState,
            let screenState = namedScenes[name] as? ScreenStateNode {
            current = screenState
            userState.initialScreenState = name
        }

        if current == nil {
            xcTest.recordFailure(withDescription: "The app's initial state couldn't be established.",
                inFile: file, atLine: line, expected: false)
        }
        return Navigator(self, xcTest: xcTest, initialScene: current!, userState: userState)
    }

    fileprivate func buildGkGraph() {
        if isReady {
            return
        }

        isReady = true

        // We have a collection of named nodes – mostly screen states.
        // Each of those have builders, so use them to build the edges.
        // However, they may also contribute some actions, which are also nodes,
        // so namedScenes here is not the same as namedScenes after this block.
        namedScenes.values.forEach { graphNode in
            if let screenStateNode = graphNode as? ScreenStateNode {
                screenStateNode.builder(screenStateNode)
            }
        }

        // Construct all the GKGraphNodes, and add them to the GKGraph.
        let graphNodes = namedScenes.values
        gkGraph.add(graphNodes.map { $0.gkNode })

        graphNodes.forEach { graphNode in
            nodedScenes[graphNode.gkNode] = graphNode
        }

        // Now, we should have a good idea what the edges of the nodes look like,
        // so we need to construct the GKGraph edges from it.
        graphNodes.forEach { graphNode in
            if let screenStateNode = graphNode as? ScreenStateNode {
                let gkNodes = screenStateNode.edges.keys.flatMap { self.namedScenes[$0]?.gkNode } as [GKGraphNode]
                screenStateNode.gkNode.addConnections(to: gkNodes, bidirectional: false)
            } else if let screenActionNode = graphNode as? ScreenActionNode {
                if let destName = screenActionNode.nextNodeName,
                    let destGkNode = namedScenes[destName]?.gkNode {
                    screenActionNode.gkNode.addConnections(to: [destGkNode], bidirectional: false)
                }
            }
        }
    }
}

class ScreenActionNode<T: UserState>: GraphNode<T> {
    typealias UserStateChange = (T) -> ()
    let recorder: UserStateChange?

    var nextNodeName: String?

    init(_ map: ScreenGraph<T>, name: String, then nextNodeName: String?, file: String, line: UInt, recorder: UserStateChange?) {
        self.recorder = recorder
        self.nextNodeName = nextNodeName
        super.init(map, name: name, file: file, line: line)
    }
}

typealias Gesture = () -> Void

class WaitCondition {
    let predicate: NSPredicate
    let object: Any
    let file: String
    let line: UInt

    init(_ predicate: String, object: Any, file: String, line: UInt) {
        self.predicate = NSPredicate(format: predicate)
        self.object = object
        self.file = file
        self.line = line
    }

    func wait(timeoutHandler: () -> ()) {
        waitOrTimeout(predicate, object: object, timeoutHandler: timeoutHandler)
    }
}

class GraphNode<T: UserState> {
    let name: String
    fileprivate let gkNode: GKGraphNode

    fileprivate weak var map: ScreenGraph<T>?

    fileprivate var file: String
    fileprivate var line: UInt

    init(_ map: ScreenGraph<T>, name: String, file: String, line: UInt) {
        self.map = map
        self.name = name
        self.file = file
        self.line = line

        self.gkNode = GKGraphNode()
    }
}

/**
 * The ScreenGraph is made up of nodes. It is not possible to init these directly, only by creating 
 * screen nodes from the ScreenGraph object.
 * 
 * The ScreenGraphNode has all the methods needed to define edges from this node to another node, using the usual
 * XCUIElement method of moving about.
 */
class ScreenStateNode<T: UserState>: GraphNode<T> {
    fileprivate let builder: SceneBuilder<T>
    fileprivate var edges: [String: Edge] = [:]

    typealias UserStateChange = (T) -> ()
    fileprivate let noopUserStateChange: UserStateChange = { _ in }

    // Iff this node has a backAction, this store temporarily stores 
    // the node we were at before we got to this one. This becomes the node we return to when the backAction is 
    // invoked.
    fileprivate weak var returnNode: ScreenStateNode<T>?

    fileprivate var hasBack: Bool {
        return backAction != nil
    }

    /**
     * This is an action that will cause us to go back from where we came from.
     * This is most useful when the same screen is accessible from multiple places, 
     * and we have a back button to return to where we came from.
     */
    var backAction: Gesture?

    /**
     * This flag indicates that once we've moved on from this node, we can't come back to 
     * it via `backAction`. This is especially useful for Menus, and dialogs.
     */
    var dismissOnUse: Bool = false

    fileprivate var onEnterStateRecorder: UserStateChange? = nil

    fileprivate var onExitStateRecorder: UserStateChange? = nil

    fileprivate var onEnterWaitCondition: WaitCondition? = nil

    fileprivate init(map: ScreenGraph<T>, name: String, file: String, line: UInt, builder: @escaping SceneBuilder<T>) {
        self.builder = builder
        super.init(map, name: name, file: file, line: line)
    }

    fileprivate func addEdge(_ dest: String, by edge: Edge) {
        edges[dest] = edge
        // by this time, we should've added all nodes in to the gkGraph.

        assert(map?.namedScenes[dest] != nil, "Destination scene '\(dest)' has not been created anywhere")
    }
}

private let existsPredicate = NSPredicate(format: "exists == true")
private let enabledPredicate = NSPredicate(format: "enabled == true")
private let hittablePredicate = NSPredicate(format: "hittable == true")
private let noopNodeVisitor: NodeVisitor = { _ in }

// This is a function for waiting for a condition of an object to come true.
func waitOrTimeout(_ predicate: NSPredicate = existsPredicate, object: Any, timeout: TimeInterval = 5, timeoutHandler: () -> ()) {
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: object)
    let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
    if result != .completed {
        timeoutHandler()
    }
}

// Public methods for defining edges out of this node.
extension ScreenStateNode {
    /**
     * Declare that by performing the given action/gesture, then we can navigate from this node to the next.
     * 
     * @param withElement – optional, but if provided will attempt to verify it is there before performing the action.
     * @param to – the destination node.
     */
    func gesture(withElement element: XCUIElement? = nil, to nodeName: String, file declFile: String = #file, line declLine: UInt = #line, g: @escaping () -> Void) {
        let edge = Edge(transition: { xcTest, file, line in
            if let el = element {
                waitOrTimeout(existsPredicate, object: el) { _ in
                    xcTest.recordFailure(withDescription: "Cannot find \(el)", inFile: declFile, atLine: declLine, expected: false)
                    xcTest.recordFailure(withDescription: "Cannot get from \(self.name) to \(nodeName). See \(declFile)", inFile: file, atLine: line, expected: false)
                }
            }
            g()
        })
        addEdge(nodeName, by: edge)
    }

    func noop(to nodeName: String, file: String = #file, line: UInt = #line) {
        self.gesture(to: nodeName, file: file, line: line) {
            // NOOP.
        }
    }

    /**
     * Declare that by tapping a given element, we should be able to navigate from this node to another.
     *
     * @param element - the element to tap
     * @param to – the destination node.
     */
    func tap(_ element: XCUIElement, to nodeName: String, file: String = #file, line: UInt = #line) {
        self.gesture(withElement: element, to: nodeName, file: file, line: line) {
            element.tap()
        }
    }

    func doubleTap(_ element: XCUIElement, to nodeName: String, file: String = #file, line: UInt = #line) {
        self.gesture(withElement: element, to: nodeName, file: file, line: line) {
            element.doubleTap()
        }
    }

    func typeText(_ text: String, into element: XCUIElement, to nodeName: String, file: String = #file, line: UInt = #line) {
        self.gesture(withElement: element, to: nodeName, file: file, line: line) {
            element.typeText(text)
        }
    }

    func swipeLeft(_ element: XCUIElement, to nodeName: String, file: String = #file, line: UInt = #line) {
        self.gesture(withElement: element, to: nodeName, file: file, line: line) {
            element.swipeLeft()
        }
    }

    func swipeRight(_ element: XCUIElement, to nodeName: String, file: String = #file, line: UInt = #line) {
        self.gesture(withElement: element, to: nodeName, file: file, line: line) {
            element.swipeRight()
        }
    }

    func swipeUp(_ element: XCUIElement, to nodeName: String, file: String = #file, line: UInt = #line) {
        self.gesture(withElement: element, to: nodeName, file: file, line: line) {
            element.swipeUp()
        }
    }

    func swipeDown(_ element: XCUIElement, to nodeName: String, file: String = #file, line: UInt = #line) {
        self.gesture(withElement: element, to: nodeName, file: file, line: line) {
            element.swipeDown()
        }
    }
}

extension ScreenStateNode {
    func tap(_ element: XCUIElement, forAction actions: String..., transitionTo screenState: String? = nil, file: String = #file, line: UInt = #line, r: @escaping UserStateChange) {
        map?.addActionChain(actions, finalState: screenState, r: r, file: file, line: line)
        tap(element, to: actions[0], file: file, line: line)
    }

    func gesture(withElement element: XCUIElement? = nil, forAction actions: String..., transitionTo screenState: String? = nil, file: String = #file, line: UInt = #line, r: @escaping UserStateChange) {
        map?.addActionChain(actions, finalState: screenState, r: r, file: file, line: line)
        gesture(withElement: element, to: actions[0], file: file, line: line) {
            // NOP
        }
    }
}

extension ScreenStateNode {
    /// This allows us to record state changes in the app as the navigator moves into a given screen state.
    func onEnter(_ predicate: String = "exists == true", element: Any? = nil,
                 file: String = #file, line: UInt = #line,
                 recorder: @escaping UserStateChange) {
        if let element = element {
            onEnter(predicate, element: element)
        }
        onEnterStateRecorder = recorder
    }

    func onEnter(_ predicate: String = "exists == true", element: Any, file: String = #file, line: UInt = #line) {
        onEnterWaitCondition = WaitCondition(predicate, object: element, file: file, line: line)
    }

    /// This allows us to record state changes in the app as the navigator leaves a given screen state.
    func onExit(recorder: @escaping UserStateChange) {
        onExitStateRecorder = recorder
    }
}

/**
 * The Navigator provides a set of methods to navigate around the app. You can `goto` nodes, `visit` multiple nodes,
 * or visit all nodes, but mostly you just goto. If you take actions that move around the app outside of the
 * navigator, you can re-sync app with navigator my telling it which node it is now at, using the `nowAt` method.
 */
class Navigator<T: UserState> {
    fileprivate let map: ScreenGraph<T>
    fileprivate var currentScene: GraphNode<T>
    fileprivate var returnToRecentScene: ScreenStateNode<T>
    fileprivate let xcTest: XCTestCase

    var userState: T

    var screenState: String {
        return currentScene.name
    }

    fileprivate init(_ map: ScreenGraph<T>, xcTest: XCTestCase, initialScene: ScreenStateNode<T>, userState: T) {
        self.map = map
        self.xcTest = xcTest
        self.currentScene = initialScene
        self.returnToRecentScene = initialScene
        self.userState = userState
    }

    /**
     * Move the application to the named node.
     */
    func goto(_ nodeName: String, file: String = #file, line: UInt = #line) {
        goto(nodeName, file: file, line: line, visitWith: noopNodeVisitor)
    }

    /**
     * Move the application to the named node, wth an optional node visitor closure, which is called each time the
     * node changes.
     */
    func goto(_ nodeName: String, file: String = #file, line: UInt = #line, visitWith nodeVisitor: @escaping NodeVisitor) {
        let gkSrc = currentScene.gkNode
        guard let gkDest = map.namedScenes[nodeName]?.gkNode else {
            xcTest.recordFailure(withDescription: "Cannot route to \(nodeName), because it doesn't exist", inFile: file, atLine: line, expected: false)
            return
        }

        var gkPath = map.gkGraph.findPath(from: gkSrc, to: gkDest)
        guard gkPath.count > 0 else {
            xcTest.recordFailure(withDescription: "Cannot route from \(currentScene.name) to \(nodeName)", inFile: file, atLine: line, expected: false)
            return
        }

        gkPath.removeFirst()

        var graphNodes = gkPath.flatMap { map.nodedScenes[$0] }

        // If the path ends on an action, then we should follow that action
        // until we're on a valid screen state, or there's nothing left to do.
        if let lastAction = graphNodes.last as? ScreenActionNode {
            var action = lastAction
            var extras = [GraphNode<T>]()
            while true {
                if let nextNodeName = action.nextNodeName,
                    let next = map.namedScenes[nextNodeName] {
                    extras.append(next)
                    if let nextAction = next as? ScreenActionNode<T> {
                        action = nextAction
                        continue
                    }
                }
                break
            }
            graphNodes += extras
        }

        // moveDirectlyTo lets us move from the current scene to the next.
        // We'll use it to follow the path we've calculated,
        // and to move back to the final screen state once we're done.
        // It takes care of exiting the current node, and moving to the next.
        func moveDirectlyTo(_ nextScene: GraphNode<T>) {
            if let node = currentScene as? ScreenStateNode<T> {
                leave(node, to: nextScene, file: file, line: line)
            } else if let node = currentScene as? ScreenActionNode<T> {
                leave(node, to: nextScene, file: file, line: line)
            }

            if let node = nextScene as? ScreenStateNode<T> {
                enter(node, withVisitor: nodeVisitor)
            } else if let node = nextScene as? ScreenActionNode<T> {
                enter(node)
            }
            currentScene = nextScene
        }

        // This is what we've all been leading up to.
        // We have a path, now let's follow it.
        graphNodes.forEach { nextScene in
            moveDirectlyTo(nextScene)
        }

        if let _ = currentScene as? ScreenStateNode<T> {
            // ok, we're done; we should return the app
            // back to the screen state, and this path did that.
            return
        }

        moveDirectlyTo(returnToRecentScene)
    }

    /// Perform an app action, as defined by the graph.
    /// Actions can cause userState to change. They only have one edge out,
    /// which could be another action or a screen state.
    /// This method will always return the app to a valid screen state.
    func performAction(_ screenActionName: String, file: String = #file, line: UInt = #line) {
        guard let _ = map.namedScenes[screenActionName] as? ScreenActionNode else {
            xcTest.recordFailure(withDescription: "\(screenActionName) is not an action", inFile: file, atLine: line, expected: false)
            return
        }
        goto(screenActionName, file: file, line: line)
    }

    func toggleOn(_ flag: Bool, withAction action: String, file: String = #file, line: UInt = #line) {
        if !flag {
            performAction(action, file: file, line: line)
        }
    }

    func toggleOff(_ flag: Bool, withAction action: String, file: String = #file, line: UInt = #line) {
        toggleOn(!flag, withAction: action)
    }

    /**
     * Helper method when the navigator gets out of sync with the actual app.
     * This should not be used too often, as it indicates you should probably have another node in your graph,
     * or you should be using `scene.dismissOnUse = true`.
     * Also useful if you're using XCUIElement taps directly to navigate from one node to another.
     */
    func nowAt(_ nodeName: String, file: String = #file, line: UInt = #line) {
        guard let newScene = map.namedScenes[nodeName] else {
            xcTest.recordFailure(withDescription: "Cannot force to unknown \(nodeName). Currently at \(currentScene.name)", inFile: file, atLine: line, expected: false)
            return
        }
        currentScene = newScene
    }

    /**
     * Visit the named nodes, calling the NodeVisitor the first time it is encountered.
     */
    func visitNodes(_ nodes: [String], file: String = #file, line: UInt = #line, f: @escaping NodeVisitor) {
        var visitedNodes = Set<String>()
        let desiredNodes = Set<String>(nodes)
        nodes.forEach { node in
            if visitedNodes.contains(node) {
                return
            }
            self.goto(node, file: file, line: line) { visitedNode in
                if desiredNodes.contains(visitedNode) && !visitedNodes.contains(visitedNode) {
                    f(visitedNode)
                }
                visitedNodes.insert(visitedNode)
            }
        }
    }

    /**
     * Visit all nodes, calling the NodeVisitor the first time it is encountered.
     * 
     * Some nodes may not be immediately available, depending on the state of the app.
     */
    func visitAll(_ file: String = #file, line: UInt = #line, f: @escaping NodeVisitor) {
        let nodes: [String] = self.map.namedScenes.keys.map { $0 } // keys can't be coerced into a [String]
        self.visitNodes(nodes, file: file, line: line, f: f)
    }

    /**
     * Move the app back to its initial state.
     * This may not be possible.
     */
    func revert(_ file: String = #file, line: UInt = #line) {
        if let initial = self.userState.initialScreenState {
            self.goto(initial, file: file, line: line)
        }
    }
}

// Private methods to help with goto.
fileprivate extension Navigator {
    fileprivate func leave(_ currentScene: ScreenStateNode<T>, to nextScene: GraphNode<T>, file: String, line: UInt) {
        if !currentScene.dismissOnUse {
            returnToRecentScene = currentScene
        }

        // Before moving to the next node, we may like to record the
        // state of the app.
        currentScene.onExitStateRecorder?(userState)

        if let edge = currentScene.edges[nextScene.name] {
            // We definitely have an action, so it's save to unbox.
            edge.transition(xcTest, file, line)
        }

        if currentScene.hasBack {
            // we've had a backAction, and we're going to go back the previous
            // state. Here we check if the transition above has taken us
            // back to the previous screen.
            if nextScene.name == currentScene.returnNode?.name {
                currentScene.returnNode = nil
                currentScene.gkNode.removeConnections(to: [ nextScene.gkNode ], bidirectional: false)
            }
        }
    }

    fileprivate func enter(_ nextScene: ScreenStateNode<T>, withVisitor nodeVisitor: NodeVisitor) {
        if let condition = nextScene.onEnterWaitCondition {
            condition.wait { _ in
                self.xcTest.recordFailure(withDescription: "Unsuccessfully entered \(nextScene.name)",
                    inFile: condition.file,
                    atLine: condition.line,
                    expected: false)
            }
        }

        // Now we've transitioned to the next node, we might want to note some state.
        nextScene.onEnterStateRecorder?(userState)

        if nextScene.hasBack {
            if nextScene.returnNode == nil {
                nextScene.returnNode = returnToRecentScene
                nextScene.gkNode.addConnections(to: [ returnToRecentScene.gkNode ], bidirectional: false)
                nextScene.gesture(to: returnToRecentScene.name, g: nextScene.backAction!)
            }
        }

        nodeVisitor(currentScene.name)
    }

    fileprivate func leave(_ currentScene: ScreenActionNode<T>, to nextScene: GraphNode<T>, file: String, line: UInt) {
        // NOP
    }

    fileprivate func enter(_ nextScene: ScreenActionNode<T>) {
        nextScene.recorder?(userState)
    }
}
