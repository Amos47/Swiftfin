//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import FactoryKit
import UIKit

/// Personal fork: hands the download service iOS's completion handler when the app is woken for finished downloads.
/// The service itself starts once the data stack is ready (`RootCoordinator`).
final class SwiftfinAppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        DownloadService.backgroundCompletionHandler = completionHandler
        _ = Container.shared.downloadService()
    }
}
