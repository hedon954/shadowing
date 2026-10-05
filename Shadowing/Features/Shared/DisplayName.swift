import Foundation

/// Friendlier titles for file names. Display only: never write the result back to the database.
enum DisplayName {
    /// "01-second-hand-ecommerce.mp3" -> "Second hand ecommerce".
    static func cleaned(_ fileName: String) -> String {
        var name = withoutExtension(fileName)
        if let match = name.prefixMatch(of: /^\s*\d{1,4}\s*[-_.)\s]\s*/), match.output.count < name.count {
            name = String(name[match.range.upperBound...])
        }
        name = name.replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        name = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !name.isEmpty else {
            return fileName
        }
        if !name.contains(where: \.isUppercase), let first = name.first {
            name = first.uppercased() + name.dropFirst()
        }
        return name
    }

    private static func withoutExtension(_ fileName: String) -> String {
        let pathExtension = (fileName as NSString).pathExtension
        guard !pathExtension.isEmpty, pathExtension.count <= 5,
              pathExtension.allSatisfy({ $0.isLetter || $0.isNumber })
        else {
            return fileName
        }
        let base = (fileName as NSString).deletingPathExtension
        return base.isEmpty ? fileName : base
    }
}
