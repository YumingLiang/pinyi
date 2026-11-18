import Foundation
import MosaicAppCore

/// `PreferenceDataStore` 的 `UserDefaults` 实现（记住浏览位置用，photo-picker-v0.1 §3）。
/// 和 `UserDefaultsPreferences`（布尔偏好）同一个 `UserDefaults.standard`，key 不重叠（`browse.position.*`）。
struct UserDefaultsPreferenceData: PreferenceDataStore {
    func data(forKey key: String) -> Data? { UserDefaults.standard.data(forKey: key) }

    func setData(_ data: Data?, forKey key: String) {
        if let data { UserDefaults.standard.set(data, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
    }
}
