import Foundation

extension String {
    init?(jsonObject: JsonObject, options: JSONSerialization.WritingOptions = []) {
        if let data = try? JSONSerialization.data(withJSONObject: jsonObject, options: options) {
            self.init(data: data, encoding: .utf8)
        } else {
            return nil
        }
    }
}
