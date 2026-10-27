#if os(iOS)
import SwiftUI
import UIKit

/// iPadOS 27 delivers the TV scene only while an accessory is registered on
/// the main interface. Keep this controller mounted across launcher/stream
/// transitions; older systems still connect the scene automatically.
@available(iOS 27.0, *)
struct ExternalDisplayAccessoryView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> ExternalDisplayAccessoryController {
        ExternalDisplayAccessoryController()
    }

    func updateUIViewController(_ controller: ExternalDisplayAccessoryController, context: Context) {}

    static func dismantleUIViewController(_ controller: ExternalDisplayAccessoryController, coordinator: ()) {
        controller.unregisterExternalDisplay()
    }
}

@available(iOS 27.0, *)
final class ExternalDisplayAccessoryController: UIViewController {
    private(set) var registration: UISceneAccessoryRegistration?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false

        let configuration = UISceneConfiguration()
        configuration.delegateClass = ExternalDisplayAccessorySceneDelegate.self
        registration = registerSceneAccessory(.externalNonInteractive(sceneConfiguration: configuration))
    }

    func unregisterExternalDisplay() {
        guard let registration else { return }
        unregisterSceneAccessory(registration)
        self.registration = nil
    }
}

/// Feed the accessory's scene into the same renderer used before iPadOS 27.
/// Notifications may also deliver these callbacks; the renderer's scene/window
/// guards make connection and disconnection idempotent.
@available(iOS 27.0, *)
final class ExternalDisplayAccessorySceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        ExternalDisplay.shared.sceneConnected(windowScene)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        guard let windowScene = scene as? UIWindowScene else { return }
        ExternalDisplay.shared.sceneDisconnected(windowScene)
    }
}
#endif
