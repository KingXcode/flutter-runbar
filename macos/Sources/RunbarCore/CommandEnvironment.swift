import Foundation

enum CommandEnvironment {
    static func extraPath(_ configured: String, homeDirectory: String = NSHomeDirectory()) -> String {
        let defaults = ["\(homeDirectory)/.pub-cache/bin", "\(homeDirectory)/fvm/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        let entries = configured.split(separator: ":").map(String.init) + defaults
        var seen = Set<String>()
        return entries.compactMap { entry -> String? in
            let expanded: String
            if entry == "~" { expanded = homeDirectory }
            else if entry.hasPrefix("~/") { expanded = homeDirectory + entry.dropFirst() }
            else { expanded = entry }
            return seen.insert(expanded).inserted ? expanded : nil
        }.joined(separator: ":")
    }
}
