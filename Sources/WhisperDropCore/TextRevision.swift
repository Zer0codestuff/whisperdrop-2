import Foundation

public struct TextRevision: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var actionID: String
    public var title: String
    public var text: String
    public var modelName: String
    public var created: Date

    public init(actionID: String, title: String, text: String, modelName: String) {
        id = UUID()
        self.actionID = actionID
        self.title = title
        self.text = text
        self.modelName = modelName
        created = Date()
    }
}
