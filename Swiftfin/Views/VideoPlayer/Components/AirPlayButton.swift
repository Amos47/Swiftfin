//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import AVKit
import SwiftUI

// Personal fork: the system AirPlay picker. It becomes the Cast menu when Chromecast is added.

extension VideoPlayer.PlaybackControls {

    struct AirPlayButton: UIViewRepresentable {

        func makeUIView(context: Context) -> AVRoutePickerView {
            let picker = AVRoutePickerView()
            picker.tintColor = .white
            picker.activeTintColor = .white
            picker.prioritizesVideoDevices = true
            picker.accessibilityLabel = L10n.airPlay
            return picker
        }

        func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
    }
}
