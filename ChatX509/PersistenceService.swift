import Foundation

/// Service responsible for persisting data to UserDefaults in a background queue.
/// Separates storage logic from View Models.
final class PersistenceService: @unchecked Sendable {
    static let shared = PersistenceService()
    
    private let queue = DispatchQueue(label: "com.chatx509.persistence", qos: .background)
    
    private init() {}
    
    /// Save an Encodable object to UserDefaults
    func save<T: Encodable>(_ object: T, key: String) {
        queue.async {
            if let data = try? JSONEncoder().encode(object) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }
    
    /// Load a Decodable object from UserDefaults (Synchronous - meant for init)
    func load<T: Decodable>(key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
    
    /// Asynchronously save logic using a custom closure (for read-modify-write cycles)
    func performAsyncUpdate(block: @escaping () -> Void) {
        queue.async {
            block()
        }
    }
    
    /// Remove an object
    func remove(key: String) {
        queue.async {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
