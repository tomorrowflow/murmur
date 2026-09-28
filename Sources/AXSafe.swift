import Foundation
import ApplicationServices

/// Type-checked accessors for Accessibility API values.
///
/// `AXUIElementCopyAttributeValue` hands back an `AnyObject` whose real type
/// depends on what the *other* application chose to return. Force-casting it
/// (`as! AXUIElement`, `as! AXValue`) crashes Murmur whenever a focused app
/// answers with a different CFType — Electron, Java and some cross-platform
/// toolkits do this for `AXFocusedUIElement` and `AXSelectedTextRange`. Since
/// these calls sit on the push-to-talk and read-aloud hot paths, a single
/// misbehaving frontmost app would take the whole menu-bar app down.
///
/// Every accessor here verifies the CFTypeID before casting and returns nil
/// instead of trapping.
enum AXSafe {

    /// Copy an attribute and return it only if it really is an `AXUIElement`.
    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var raw: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let value = raw,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// The system-wide focused UI element, or nil when it isn't an AXUIElement.
    static func focusedElement() -> AXUIElement? {
        element(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as String)
    }

    /// The focused window of the given process, or nil.
    static func focusedWindow(pid: pid_t) -> AXUIElement? {
        element(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as String)
    }

    /// Copy an attribute expected to hold an `AXValue` of the given type and
    /// unwrap it. Returns nil if the attribute is missing or the wrong type.
    static func value<T>(_ element: AXUIElement, _ attribute: String, _ type: AXValueType, into out: inout T) -> Bool {
        var raw: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let value = raw,
              CFGetTypeID(value) == AXValueGetTypeID() else { return false }
        return AXValueGetValue((value as! AXValue), type, &out)
    }

    /// Selected-text range of a text element, or nil.
    static func selectedTextRange(_ element: AXUIElement) -> CFRange? {
        var range = CFRange(location: 0, length: 0)
        guard value(element, kAXSelectedTextRangeAttribute as String, .cfRange, into: &range) else { return nil }
        return range
    }

    /// Unwrap a parameterized-attribute result expected to be an `AXValue`.
    static func unwrap<T>(_ raw: AnyObject?, _ type: AXValueType, into out: inout T) -> Bool {
        guard let value = raw, CFGetTypeID(value) == AXValueGetTypeID() else { return false }
        return AXValueGetValue((value as! AXValue), type, &out)
    }
}
