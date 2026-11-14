import AppKit
import Carbon

enum KeyModifier: String, Codable, CaseIterable, Hashable, Sendable {
    case command
    case option
    case control
    case shift

    var symbol: String {
        switch self {
        case .command: return "⌘"
        case .option: return "⌥"
        case .control: return "⌃"
        case .shift: return "⇧"
        }
    }

    var carbonMask: UInt32 {
        switch self {
        case .command: return UInt32(cmdKey)
        case .option: return UInt32(optionKey)
        case .control: return UInt32(controlKey)
        case .shift: return UInt32(shiftKey)
        }
    }

    static func from(eventFlags: NSEvent.ModifierFlags) -> [KeyModifier] {
        var result: [KeyModifier] = []
        if eventFlags.contains(.control) { result.append(.control) }
        if eventFlags.contains(.option) { result.append(.option) }
        if eventFlags.contains(.shift) { result.append(.shift) }
        if eventFlags.contains(.command) { result.append(.command) }
        return result
    }
}

/// Human-readable, JSON-serializable global shortcut representation.
struct ShortcutSpec: Codable, Equatable, Hashable, Sendable {
    var key: String
    var modifiers: [KeyModifier]

    var tokens: [String] {
        let ordered: [KeyModifier] = [.control, .option, .shift, .command]
        var result = ordered
            .filter { modifiers.contains($0) }
            .map(\.symbol)
        result.append(key.uppercased())
        return result
    }

    var displayString: String {
        tokens.joined(separator: " ")
    }

    var carbonModifiers: UInt32 {
        modifiers.reduce(0) { $0 | $1.carbonMask }
    }

    var carbonKeyCode: UInt32? {
        Self.keyMap[key.lowercased()]
    }

    static func keyName(for keyCode: UInt16) -> String? {
        reverseKeyMap[UInt32(keyCode)]
    }

    static let selectableKeys: [String] = {
        let letters = (65...90).map { String(UnicodeScalar($0)).lowercased() }
        let digits = (0...9).map { String($0) }
        let specials = ["space", "return", "tab", "-", "=", "[", "]", ";", "'", ",", ".", "/", "\\", "`"]
        return letters + digits + specials
    }()

    private static let keyMap: [String: UInt32] = [
        "a": UInt32(kVK_ANSI_A), "b": UInt32(kVK_ANSI_B), "c": UInt32(kVK_ANSI_C),
        "d": UInt32(kVK_ANSI_D), "e": UInt32(kVK_ANSI_E), "f": UInt32(kVK_ANSI_F),
        "g": UInt32(kVK_ANSI_G), "h": UInt32(kVK_ANSI_H), "i": UInt32(kVK_ANSI_I),
        "j": UInt32(kVK_ANSI_J), "k": UInt32(kVK_ANSI_K), "l": UInt32(kVK_ANSI_L),
        "m": UInt32(kVK_ANSI_M), "n": UInt32(kVK_ANSI_N), "o": UInt32(kVK_ANSI_O),
        "p": UInt32(kVK_ANSI_P), "q": UInt32(kVK_ANSI_Q), "r": UInt32(kVK_ANSI_R),
        "s": UInt32(kVK_ANSI_S), "t": UInt32(kVK_ANSI_T), "u": UInt32(kVK_ANSI_U),
        "v": UInt32(kVK_ANSI_V), "w": UInt32(kVK_ANSI_W), "x": UInt32(kVK_ANSI_X),
        "y": UInt32(kVK_ANSI_Y), "z": UInt32(kVK_ANSI_Z),
        "0": UInt32(kVK_ANSI_0), "1": UInt32(kVK_ANSI_1), "2": UInt32(kVK_ANSI_2),
        "3": UInt32(kVK_ANSI_3), "4": UInt32(kVK_ANSI_4), "5": UInt32(kVK_ANSI_5),
        "6": UInt32(kVK_ANSI_6), "7": UInt32(kVK_ANSI_7), "8": UInt32(kVK_ANSI_8),
        "9": UInt32(kVK_ANSI_9),
        "space": UInt32(kVK_Space), "return": UInt32(kVK_Return), "tab": UInt32(kVK_Tab),
        "escape": UInt32(kVK_Escape), "delete": UInt32(kVK_Delete),
        "-": UInt32(kVK_ANSI_Minus), "=": UInt32(kVK_ANSI_Equal),
        "[": UInt32(kVK_ANSI_LeftBracket), "]": UInt32(kVK_ANSI_RightBracket),
        ";": UInt32(kVK_ANSI_Semicolon), "'": UInt32(kVK_ANSI_Quote),
        ",": UInt32(kVK_ANSI_Comma), ".": UInt32(kVK_ANSI_Period),
        "/": UInt32(kVK_ANSI_Slash), "\\": UInt32(kVK_ANSI_Backslash),
        "`": UInt32(kVK_ANSI_Grave)
    ]

    private static let reverseKeyMap: [UInt32: String] = {
        var dict: [UInt32: String] = [:]
        for (name, code) in keyMap {
            dict[code] = name
        }
        return dict
    }()
}
