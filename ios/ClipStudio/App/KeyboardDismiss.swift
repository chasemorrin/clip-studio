import UIKit

/// Tapping anywhere outside a text box closes the keyboard, everywhere in the app.
/// The tap still goes through to whatever was tapped (buttons, tabs, lists).
@MainActor
enum KeyboardDismiss {
    private static let helper = Helper()

    static func install() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows where !(window.gestureRecognizers ?? []).contains(where: { $0.delegate === helper }) {
                let tap = UITapGestureRecognizer(target: helper, action: #selector(Helper.tapped(_:)))
                tap.cancelsTouchesInView = false
                tap.delegate = helper
                window.addGestureRecognizer(tap)
            }
        }
    }

    final class Helper: NSObject, UIGestureRecognizerDelegate {
        @objc func tapped(_ tap: UITapGestureRecognizer) {
            tap.view?.endEditing(true)
        }

        // Don't close the keyboard when the tap lands in a text box (so you can move between fields).
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let v = view {
                if v is UITextField || v is UITextView { return false }
                view = v.superview
            }
            return true
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}
