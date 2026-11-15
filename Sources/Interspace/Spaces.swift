import AppKit

/// The ordered spaces of one display.
struct SpaceLayout {
    let displayUUID: String
    let spaceIDs: [UInt64]
    var currentIndex: Int
    /// Normal desktops, without the spaces of full-screen apps.
    let desktopIDs: [UInt64]
    let screen: NSScreen

    var displayID: CGDirectDisplayID { screen.displayID }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }

    static var underCursor: NSScreen? {
        let location = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(location, $0.frame, false) } ?? main ?? screens.first
    }
}

/// Read-only access to the space list through private CoreGraphics services.
enum Spaces {
    private typealias MainConnectionFn = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpacesFn = @convention(c) (Int32, CFString?) -> Unmanaged<CFArray>?

    private static let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)

    private static let mainConnection: MainConnectionFn? = {
        guard let pointer = dlsym(rtldDefault, "CGSMainConnectionID") else { return nil }
        return unsafeBitCast(pointer, to: MainConnectionFn.self)
    }()

    private typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    private static let copySpacesForWindows: CopySpacesForWindowsFn? = {
        guard let pointer = dlsym(rtldDefault, "CGSCopySpacesForWindows") else { return nil }
        return unsafeBitCast(pointer, to: CopySpacesForWindowsFn.self)
    }()

    /// The spaces a window is on. Empty when unknown, or when the window was never on screen.
    static func spaces(ofWindow windowNumber: Int) -> [UInt64] {
        guard windowNumber > 0, let mainConnection, let copySpacesForWindows else { return [] }
        let allSpaces: Int32 = 7
        let windows = [NSNumber(value: windowNumber)] as CFArray
        let spaces = copySpacesForWindows(mainConnection(), allSpaces, windows)?.takeRetainedValue() as? [NSNumber]
        return spaces?.map { $0.uint64Value } ?? []
    }

    private static let copyManagedDisplaySpaces: CopyManagedDisplaySpacesFn? = {
        guard let pointer = dlsym(rtldDefault, "CGSCopyManagedDisplaySpaces") else { return nil }
        return unsafeBitCast(pointer, to: CopyManagedDisplaySpacesFn.self)
    }()

    static var isAvailable: Bool {
        mainConnection != nil && copyManagedDisplaySpaces != nil
    }

    static func layout(for screen: NSScreen) -> SpaceLayout? {
        guard let mainConnection, let copyManagedDisplaySpaces else { return nil }
        let connection = mainConnection()
        guard connection != 0,
              let displays = copyManagedDisplaySpaces(connection, nil)?.takeRetainedValue() as? [[String: Any]],
              !displays.isEmpty
        else { return nil }

        let uuid = displayUUID(for: screen)
        // With "Displays have separate Spaces" off there is one entry, named "Main".
        let entry = displays.first { ($0["Display Identifier"] as? String) == uuid } ?? displays[0]

        guard let spaces = entry["Spaces"] as? [[String: Any]] else { return nil }
        let ids = spaces.compactMap { ($0["id64"] as? NSNumber)?.uint64Value }
        guard !ids.isEmpty,
              let current = ((entry["Current Space"] as? [String: Any])?["id64"] as? NSNumber)?.uint64Value,
              let index = ids.firstIndex(of: current)
        else { return nil }

        let desktops = spaces.compactMap { space -> UInt64? in
            guard (space["type"] as? NSNumber)?.intValue == 0 else { return nil }
            return (space["id64"] as? NSNumber)?.uint64Value
        }

        return SpaceLayout(
            displayUUID: (entry["Display Identifier"] as? String) ?? uuid ?? "Main",
            spaceIDs: ids,
            currentIndex: index,
            desktopIDs: desktops,
            screen: screen
        )
    }

    private static func displayUUID(for screen: NSScreen) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(screen.displayID)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }
}
