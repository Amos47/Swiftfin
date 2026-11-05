//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import JellyfinAPI
import SwiftUI

// Personal fork: links to the show on TVDB, IMDb and TMDB, from its provider IDs.

struct ExternalLinksGroup: ContentGroup {

    struct ExternalLink: Hashable {
        let title: String
        let url: URL
    }

    let id = "external-links"
    let item: BaseItemDto

    var links: [ExternalLink] {
        let ids = item.providerIDs ?? [:]
        let isSeries = item.type == .series
        var links: [ExternalLink] = []

        if let tvdb = ids["Tvdb"], let url = URL(string: "https://thetvdb.com/?tab=\(isSeries ? "series" : "movie")&id=\(tvdb)") {
            links.append(.init(title: "TVDB", url: url))
        }
        if let imdb = ids["Imdb"], let url = URL(string: "https://www.imdb.com/title/\(imdb)") {
            links.append(.init(title: "IMDb", url: url))
        }
        if let tmdb = ids["Tmdb"], let url = URL(string: "https://www.themoviedb.org/\(isSeries ? "tv" : "movie")/\(tmdb)") {
            links.append(.init(title: "TMDB", url: url))
        }
        return links
    }

    var _shouldBeResolved: Bool {
        links.isNotEmpty
    }

    func body(with viewModel: Empty) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.externalLinks)
                .font(.title2)
                .fontWeight(.semibold)
                .accessibilityAddTraits(.isHeader)

            HStack(spacing: 10) {
                ForEach(links, id: \.self) { link in
                    Link(destination: link.url) {
                        Text(verbatim: link.title)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.secondary.opacity(0.2), in: Capsule())
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .edgePadding(.horizontal)
    }
}
