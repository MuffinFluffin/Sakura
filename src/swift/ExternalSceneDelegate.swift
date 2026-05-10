// SPDX-License-Identifier: GPL-3.0+

import SwiftUI
import UIKit

@MainActor
@objc(ExternalSceneDelegate)
final class ExternalSceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        NSLog("[Sakura] external scene connect role=\(session.role.rawValue)")
        guard let windowScene = scene as? UIWindowScene else { return }
        windowScene.screen.overscanCompensation = .scale
        let window = UIWindow(windowScene: windowScene)
        window.backgroundColor = .black
        window.isHidden = false
        self.window = window
        SecondaryDisplayCoordinator.shared.adoptExternalSceneWindow(window)
        NSLog("[Sakura] external scene adopted bounds=\(NSCoder.string(for: windowScene.screen.bounds))")
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        NSLog("[Sakura] external scene disconnect")
        SecondaryDisplayCoordinator.shared.releaseExternalSceneWindow(self.window)
        self.window = nil
    }
}
