import Foundation

enum AppGroup {
    static let identifier = "group.com.app.xtubee"
    static let enabledSectionsKey = "topShelf.enabledSections"

    static var defaults: UserDefaults {
        UserDefaults(suiteName: identifier) ?? .standard
    }
}
