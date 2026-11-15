import CDockSwipe
import Foundation

/// The keyboard shortcuts of macOS for "Move left a space" and "Move right a space".
///
/// macOS starts its own transition for them. The app takes the key presses before macOS reads them,
/// and does its own transition instead.
enum SpaceShortcuts {
    /// Called on the main thread: -1 for the space to the left, +1 for the space to the right.
    static var onStep: ((Int) -> Void)?

    // The numbers macOS gives these two shortcuts in its settings.
    private static let moveLeftID = "79"
    private static let moveRightID = "81"
    private static let leftArrow = 123
    private static let rightArrow = 124
    private static let control: UInt64 = 0x40000

    private static let systemSettings = UserDefaults(suiteName: "com.apple.symbolichotkeys")

    /// Needs Accessibility permission. Safe to call again.
    static func install() -> Bool {
        ds_keys_install { direction in
            // This is the thread of the keyboard tap. The work is for the main thread.
            let step = direction == DSDirectionRight ? 1 : -1
            DispatchQueue.main.async {
                SpaceShortcuts.onStep?(step)
            }
        }
    }

    /// Reads the shortcuts from the settings of macOS and turns the tap on or off.
    /// The user can change them, or turn them off, in System Settings > Keyboard > Keyboard Shortcuts.
    static func update(enabled: Bool) {
        guard enabled else {
            ds_keys_configure(false, -1, 0, -1, 0)
            return
        }
        let all = systemSettings?.dictionary(forKey: "AppleSymbolicHotKeys") ?? [:]
        let left = shortcut(all[moveLeftID], defaultKey: leftArrow)
        let right = shortcut(all[moveRightID], defaultKey: rightArrow)
        ds_keys_configure(left != nil || right != nil, Int32(left?.key ?? -1), left?.flags ?? 0, Int32(right?.key ?? -1), right?.flags ?? 0)
    }

    /// Nil when the user turned the shortcut off.
    private static func shortcut(_ entry: Any?, defaultKey: Int) -> (key: Int, flags: UInt64)? {
        // No entry: the user never changed it, and it is Control with an arrow key.
        guard let entry = entry as? [String: Any] else { return (defaultKey, control) }
        guard (entry["enabled"] as? NSNumber)?.boolValue ?? true else { return nil }
        // The parameters are a character, a key code and the modifier flags.
        guard let value = entry["value"] as? [String: Any],
              let parameters = value["parameters"] as? [NSNumber], parameters.count >= 3
        else { return (defaultKey, control) }
        return (parameters[1].intValue, parameters[2].uint64Value)
    }
}
