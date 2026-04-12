import Foundation

/// Minimal agent state model for dashboard (reads .cursor/agent-state.json).
public struct AgentState: Codable {
    public var updatedAt: String
    public var agents: [AgentEntry]
    public var tasks: [TaskEntry]

    public struct AgentEntry: Codable {
        public var id: String
        public var name: String
        public var status: String
        public var currentFile: String
        public var taskDescription: String
        public var lastActivityAt: String
    }

    public struct TaskEntry: Codable {
        public var id: String
        public var title: String
        public var phase: String
        public var priority: String
        public var status: String
        public var assignedAgent: String
        public var estimatedHours: Int
        public var dependencyIds: [String]
    }
}
