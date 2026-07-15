import XCTest
@testable import IntatisConversation

final class ExplicitGoalIntentClassifierTests: XCTestCase {
    func testRecognizesExplicitEnglishPersistentGoalRequests() {
        let requests = [
            "Set shipping v1 as an ongoing goal.",
            "Please make fixing all release blockers a persistent goal",
            "Could you turn the migration into a long-term goal?",
            "I want you to create an ongoing goal to finish the audit",
            "Establish a durable goal: keep the release green",
        ]

        for request in requests {
            XCTAssertEqual(
                ExplicitGoalIntentClassifier.classify(request),
                .createPersistentGoal,
                request)
        }
    }

    func testRecognizesExplicitChinesePersistentGoalRequests() {
        let requests = [
            "把发布 v1 设成一个持续目标",
            "请将修完所有阻塞项设置为长期目标。",
            "麻烦你把迁移工作标记为持久目标",
            "创建一个持续目标：完成安全审计",
            "我希望你建立长期目标来保持构建通过",
        ]

        for request in requests {
            XCTAssertEqual(
                ExplicitGoalIntentClassifier.classify(request),
                .createPersistentGoal,
                request)
        }
    }

    func testGeneralGoalMentionsAndComplexRequestsRemainOrdinaryTurns() {
        let ordinaryTurns = [
            "Implement the complete release workflow and verify every edge case",
            "My long-term goal is to ship v1",
            "Can you help me achieve this ongoing goal?",
            "Explain what an ongoing goal means",
            "Create a goal to ship v1",
            "The word goal appears in this ordinary request",
            "完成整个发布流程并验证所有边界情况",
            "我的长期目标是发布 v1",
            "请帮我完成这个持续目标",
            "解释一下什么是持续目标",
            "创建目标列表",
        ]

        for request in ordinaryTurns {
            XCTAssertEqual(
                ExplicitGoalIntentClassifier.classify(request),
                .ordinaryTurn,
                request)
        }
    }

    func testEmptyAndQuotedExamplesDoNotGrantExplicitIntent() {
        XCTAssertEqual(ExplicitGoalIntentClassifier.classify("   \n"), .ordinaryTurn)
        XCTAssertEqual(
            ExplicitGoalIntentClassifier.classify("Explain the phrase ‘set X as an ongoing goal’"),
            .ordinaryTurn)
        XCTAssertEqual(
            ExplicitGoalIntentClassifier.classify("分析‘把 X 设成一个持续目标’这句话"),
            .ordinaryTurn)
    }
}
