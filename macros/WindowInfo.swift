import Foundation

struct WindowInfo: Identifiable, Decodable {
    let id: Int
    let appName: String
    let title: String
    let workspace: String?
    
    enum CodingKeys: String, CodingKey {
        case id = "window-id"
        case appName = "app-name"
        case title = "window-title"
        case workspace
    }
}
