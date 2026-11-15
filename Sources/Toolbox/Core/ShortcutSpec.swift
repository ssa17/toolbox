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
    static let none = ShortcutSpec(key: "", modifiers: [])

    var key: String
    var modifiers: [KeyModifier]

    init(key: String, modifiers: [KeyModifier]) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.key = trimmed
        let ordered: [KeyModifier] = [.control, .option, .shift, .command]
        self.modifiers = trimmed.isEmpty ? [] : ordered.filter { modifiers.contains($0) }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedKey = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        let decodedMods = try c.decodeIfPresent([KeyModifier].self, forKey: .modifiers) ?? []
        self.init(key: decodedKey, modifiers: decodedMods)
    }

    var isEmpty: Bool {
        key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isFunctionKey: Bool {
        guard let code = carbonKeyCode else { return false }
        return Self.functionKeyCodes.contains(code)
    }

    var tokens: [String] {
        guard !isEmpty else { return [] }
        let ordered: [KeyModifier] = [.control, .option, .shift, .command]
        var result = ordered
            .filter { modifiers.contains($0) }
            .map(\.symbol)
        result.append(keyDisplayLabel)
        return result
    }

    var displayString: String {
        tokens.joined(separator: " ")
    }

    var keyDisplayLabel: String {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let special = Self.specialDisplayLabels[normalized] {
            return special
        }
        if let code = Self.keyMap[normalized] {
            if Self.functionKeyCodes.contains(code) {
                return normalized.uppercased()
            }
            if !Self.keypadKeyCodes.contains(code),
               let translated = Self.layoutCharacter(for: UInt16(code)) {
                return translated
            }
        }
        return normalized.uppercased()
    }

    var carbonModifiers: UInt32 {
        modifiers.reduce(0) { $0 | $1.carbonMask }
    }

    var carbonKeyCode: UInt32? {
        guard !isEmpty else { return nil }
        return Self.keyMap[key.lowercased()]
    }

    static func keyName(for keyCode: UInt16) -> String? {
        reverseKeyMap[UInt32(keyCode)]
    }

    private static func layoutCharacter(for keyCode: UInt16) -> String? {
        guard Thread.isMainThread else { return nil }
        let sources: [TISInputSource?] = [
            TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
        ]
        for source in sources {
            guard let source,
                  let rawPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
                continue
            }
            let layoutData = unsafeBitCast(rawPtr, to: CFData.self)
            guard let bytePtr = CFDataGetBytePtr(layoutData) else { continue }
            let layoutPtr = bytePtr.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { $0 }

            var deadKeyState: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layoutPtr,
                keyCode,
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                chars.count,
                &length,
                &chars
            )
            guard status == noErr, length > 0 else { continue }
            let str = String(utf16CodeUnits: chars, count: length)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !str.isEmpty else { continue }
            let isPrintable = str.unicodeScalars.allSatisfy { scalar in
                (scalar.value >= 0x21 && scalar.value <= 0x7E)
                    || (scalar.value >= 0xA1 && scalar.value < 0x2000)
            }
            if isPrintable {
                return str.uppercased()
            }
        }
        return nil
    }

    private static let specialDisplayLabels: [String: String] = [
        "space": "Space",
        "return": "↩",
        "enter": "⌤",
        "tab": "⇥",
        "delete": "⌫",
        "forwarddelete": "⌦",
        "escape": "⎋",
        "up": "↑",
        "down": "↓",
        "left": "←",
        "right": "→",
        "home": "↖",
        "end": "↘",
        "pageup": "⇞",
        "pagedown": "⇟",
        "num0": "Num0", "num1": "Num1", "num2": "Num2", "num3": "Num3", "num4": "Num4",
        "num5": "Num5", "num6": "Num6", "num7": "Num7", "num8": "Num8", "num9": "Num9",
        "num.": "Num.", "num*": "Num*", "num+": "Num+", "numclear": "Clear",
        "num/": "Num/", "num-": "Num-", "num=": "Num="
    ]

    private static let functionKeyCodes: Set<UInt32> = [
        UInt32(kVK_F1), UInt32(kVK_F2), UInt32(kVK_F3), UInt32(kVK_F4),
        UInt32(kVK_F5), UInt32(kVK_F6), UInt32(kVK_F7), UInt32(kVK_F8),
        UInt32(kVK_F9), UInt32(kVK_F10), UInt32(kVK_F11), UInt32(kVK_F12),
        UInt32(kVK_F13), UInt32(kVK_F14), UInt32(kVK_F15), UInt32(kVK_F16),
        UInt32(kVK_F17), UInt32(kVK_F18), UInt32(kVK_F19), UInt32(kVK_F20)
    ]

    private static let keypadKeyCodes: Set<UInt32> = [
        UInt32(kVK_ANSI_Keypad0), UInt32(kVK_ANSI_Keypad1), UInt32(kVK_ANSI_Keypad2),
        UInt32(kVK_ANSI_Keypad3), UInt32(kVK_ANSI_Keypad4), UInt32(kVK_ANSI_Keypad5),
        UInt32(kVK_ANSI_Keypad6), UInt32(kVK_ANSI_Keypad7), UInt32(kVK_ANSI_Keypad8),
        UInt32(kVK_ANSI_Keypad9), UInt32(kVK_ANSI_KeypadDecimal), UInt32(kVK_ANSI_KeypadMultiply),
        UInt32(kVK_ANSI_KeypadPlus), UInt32(kVK_ANSI_KeypadClear), UInt32(kVK_ANSI_KeypadDivide),
        UInt32(kVK_ANSI_KeypadMinus), UInt32(kVK_ANSI_KeypadEquals)
    ]

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
        "f1": UInt32(kVK_F1), "f2": UInt32(kVK_F2), "f3": UInt32(kVK_F3), "f4": UInt32(kVK_F4),
        "f5": UInt32(kVK_F5), "f6": UInt32(kVK_F6), "f7": UInt32(kVK_F7), "f8": UInt32(kVK_F8),
        "f9": UInt32(kVK_F9), "f10": UInt32(kVK_F10), "f11": UInt32(kVK_F11), "f12": UInt32(kVK_F12),
        "f13": UInt32(kVK_F13), "f14": UInt32(kVK_F14), "f15": UInt32(kVK_F15), "f16": UInt32(kVK_F16),
        "f17": UInt32(kVK_F17), "f18": UInt32(kVK_F18), "f19": UInt32(kVK_F19), "f20": UInt32(kVK_F20),
        "up": UInt32(kVK_UpArrow), "down": UInt32(kVK_DownArrow),
        "left": UInt32(kVK_LeftArrow), "right": UInt32(kVK_RightArrow),
        "space": UInt32(kVK_Space), "return": UInt32(kVK_Return),
        "enter": UInt32(kVK_ANSI_KeypadEnter), "tab": UInt32(kVK_Tab),
        "escape": UInt32(kVK_Escape), "delete": UInt32(kVK_Delete),
        "forwarddelete": UInt32(kVK_ForwardDelete),
        "home": UInt32(kVK_Home), "end": UInt32(kVK_End),
        "pageup": UInt32(kVK_PageUp), "pagedown": UInt32(kVK_PageDown),
        "num0": UInt32(kVK_ANSI_Keypad0), "num1": UInt32(kVK_ANSI_Keypad1),
        "num2": UInt32(kVK_ANSI_Keypad2), "num3": UInt32(kVK_ANSI_Keypad3),
        "num4": UInt32(kVK_ANSI_Keypad4), "num5": UInt32(kVK_ANSI_Keypad5),
        "num6": UInt32(kVK_ANSI_Keypad6), "num7": UInt32(kVK_ANSI_Keypad7),
        "num8": UInt32(kVK_ANSI_Keypad8), "num9": UInt32(kVK_ANSI_Keypad9),
        "num.": UInt32(kVK_ANSI_KeypadDecimal), "num*": UInt32(kVK_ANSI_KeypadMultiply),
        "num+": UInt32(kVK_ANSI_KeypadPlus), "numclear": UInt32(kVK_ANSI_KeypadClear),
        "num/": UInt32(kVK_ANSI_KeypadDivide), "num-": UInt32(kVK_ANSI_KeypadMinus),
        "num=": UInt32(kVK_ANSI_KeypadEquals),
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
