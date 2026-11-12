import ApplicationServices
@testable import MeetingTranscriber
import XCTest

/// The roster read runs on the main actor at the start of every Teams
/// meeting, so how long it may take is bounded here, against a fake AX tree:
/// a Teams that stopped answering, or one with a very large tree, must not
/// hold the menu bar for longer than the read's budget.
final class ParticipantReaderBoundsTests: XCTestCase {
    /// A Teams whose process hangs answers every call with `.cannotComplete`,
    /// each after a full messaging timeout. One such answer ends the read;
    /// without that, every walk would wait out its own timeouts.
    func testAnUnresponsiveAppEndsTheReadAtItsFirstCall() {
        let tree = FakeAXTree(root: FakeAXTree.Node(role: "AXApplication"))
        tree.failEveryCall = true

        XCTAssertNil(tree.read())
        XCTAssertEqual(tree.calls, 1, "the read kept calling into an app that had stopped answering")
    }

    /// A large tree with no roster in it: the read stops once its budget is
    /// spent instead of walking every element, seven times over.
    func testALargeTreeIsCutOffAtTheReadBudget() {
        let tree = FakeAXTree(root: FakeAXTree.Node.wide(depth: 6, branching: 3))
        tree.secondsPerCall = 0.1

        XCTAssertNil(tree.read())
        let budgetCalls = Int((ParticipantReader.readBudget / 0.1).rounded(.up))
        XCTAssertGreaterThan(tree.calls, 0)
        XCTAssertLessThanOrEqual(tree.calls, budgetCalls + 1, "the read ran past its budget")
    }

    /// The window title names the participants of a small call and costs a
    /// handful of calls, where the roster walks cost the whole tree. With the
    /// roster panel closed, the usual case, those walks find nothing and on a
    /// large tree spend the budget doing so; the title must not be lost to
    /// that, or bounding the read would cost the suggestions it used to give.
    func testTheWindowTitleSurvivesRosterWalksThatSpendTheBudget() {
        let window = FakeAXTree.Node(
            role: kAXWindowRole as String, title: "Speaker A, Speaker B | Microsoft Teams",
            children: [FakeAXTree.Node.wide(depth: 6, branching: 3)],
        )
        let tree = FakeAXTree(root: FakeAXTree.Node(role: "AXApplication", children: [window]))
        tree.secondsPerCall = 0.1

        XCTAssertEqual(tree.read(), ["Speaker A", "Speaker B"])
        let budgetCalls = Int((ParticipantReader.readBudget / 0.1).rounded(.up))
        XCTAssertLessThanOrEqual(tree.calls, budgetCalls + 1, "the read ran past its budget")
    }

    /// A roster the budget cut off part way is not a roster: its first rows
    /// would be offered as if they were everyone, and would beat the title,
    /// which was read in full. A read that was cut short falls back to the
    /// title instead.
    func testARosterCutOffByTheBudgetDoesNotBeatTheWindowTitle() {
        let rows = (0 ..< 40).map { FakeAXTree.Node(role: kAXStaticTextRole as String, value: "Speaker \($0)") }
        let panel = FakeAXTree.Node(role: "AXGroup", identifier: "roster-list", children: rows)
        let window = FakeAXTree.Node(
            role: kAXWindowRole as String, title: "Speaker X, Speaker Y | Microsoft Teams", children: [panel],
        )
        let tree = FakeAXTree(root: FakeAXTree.Node(role: "AXApplication", children: [window]))
        tree.secondsPerCall = 0.1

        XCTAssertEqual(tree.read(), ["Speaker X", "Speaker Y"])
    }

    /// Each element is asked with the short timeout, not the system default:
    /// a timeout set on one element does not carry over to the elements read
    /// from it.
    func testEveryElementIsReadWithTheShortTimeout() {
        let tree = FakeAXTree(root: FakeAXTree.Node.wide(depth: 2, branching: 2))

        _ = tree.read()

        XCTAssertFalse(tree.queriedPIDs.isEmpty)
        XCTAssertTrue(tree.queriedPIDs.isSubset(of: tree.timeouts.keys), "an element was read with the default timeout")
        XCTAssertEqual(Set(tree.timeouts.values), [ParticipantReader.callTimeout])
    }

    /// The control: the bounds leave a normal roster readable.
    func testARosterPanelIsStillFound() {
        let panel = FakeAXTree.Node(role: "AXGroup", identifier: "roster-list", children: [
            FakeAXTree.Node(role: kAXStaticTextRole as String, value: "Speaker A"),
            FakeAXTree.Node(role: kAXStaticTextRole as String, value: "Speaker B"),
        ])
        let tree = FakeAXTree(root: FakeAXTree.Node(role: "AXApplication", children: [panel]))

        XCTAssertEqual(tree.read(), ["Speaker A", "Speaker B"])
    }
}

/// An AX tree answered from memory. Elements are application elements for
/// made-up pids, which are only identifiers here: creating one sends nothing,
/// and every read goes to this fake, never to a real process.
private final class FakeAXTree {
    final class Node {
        let role: String
        let identifier: String?
        let value: String?
        let title: String?
        let children: [Node]

        init(role: String, identifier: String? = nil, value: String? = nil, title: String? = nil, children: [Node] = []) {
            self.role = role
            self.identifier = identifier
            self.value = value
            self.title = title
            self.children = children
        }

        static func wide(depth: Int, branching: Int) -> Node {
            let children = depth == 0 ? [] : (0 ..< branching).map { _ in wide(depth: depth - 1, branching: branching) }
            return Node(role: "AXGroup", children: children)
        }
    }

    private var nodes: [pid_t: Node] = [:]
    private var elements: [ObjectIdentifier: AXUIElement] = [:]
    private let rootPID: pid_t
    var failEveryCall = false
    var secondsPerCall: TimeInterval = 0
    private(set) var calls = 0
    private(set) var clock: TimeInterval = 0
    private(set) var queriedPIDs: Set<pid_t> = []
    private(set) var timeouts: [pid_t: Float] = [:]

    init(root: Node) {
        var next: pid_t = 100_000
        var pending = [root]
        var pids: [ObjectIdentifier: pid_t] = [:]
        while let node = pending.popLast() {
            pids[ObjectIdentifier(node)] = next
            nodes[next] = node
            next += 1
            pending.append(contentsOf: node.children)
        }
        rootPID = pids[ObjectIdentifier(root)] ?? 0
        for (id, pid) in pids {
            elements[id] = AXUIElementCreateApplication(pid)
        }
    }

    func read() -> [String]? { // swiftlint:disable:this discouraged_optional_collection
        ParticipantReader.readParticipants(
            pid: rootPID, isTrusted: { true }, makeRoot: AXUIElementCreateApplication,
            access: ParticipantReader.RosterAccess(
                copyAttribute: { [self] element, attribute in copy(element, attribute) },
                setTimeout: { [self] element, seconds in timeouts[pid(of: element)] = seconds },
                now: { [self] in clock },
            ),
        )
    }

    private func pid(of element: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        _ = AXUIElementGetPid(element, &pid)
        return pid
    }

    private func copy(_ element: AXUIElement, _ attribute: String) -> (value: AnyObject?, error: AXError) {
        calls += 1
        clock += secondsPerCall
        let pid = pid(of: element)
        queriedPIDs.insert(pid)
        if failEveryCall { return (nil, .cannotComplete) }
        guard let node = nodes[pid] else { return (nil, .invalidUIElement) }
        let value: AnyObject? = switch attribute {
        case kAXRoleAttribute: node.role as AnyObject
        case "AXIdentifier": node.identifier.map { $0 as AnyObject }
        case kAXValueAttribute: node.value.map { $0 as AnyObject }
        case kAXTitleAttribute: node.title.map { $0 as AnyObject }
        case kAXChildrenAttribute: node.children.compactMap { elements[ObjectIdentifier($0)] } as AnyObject
        default: nil
        }
        return value.map { ($0, .success) } ?? (nil, .noValue)
    }
}
