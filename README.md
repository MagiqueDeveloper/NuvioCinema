# Nuvio Cinema

Nuvio Cinema is an independent native tvOS client built for a premium streaming experience on Apple TV. Browse cinematic collections, navigate with the Siri Remote, and watch with scrub previews and subtitle controls designed for the big screen. Link your Nuvio account to bring your sources and Continue Watching across devices.

## Features

- A full-screen Home hero that rotates daily, with trending movies and series, new releases, and genre collections.
- Native search with a mixed movie and series grid, plus title pages with episodes, trailers, cast, and related titles.
- Nuvio account linking by QR code, synced Continue Watching, and Home’s featured titles in Apple TV Top Shelf.
- AetherEngine and MPVKit playback, scrub previews, subtitle timing and sync, and IntroDB skip controls where markers are available.

[Cinemeta](https://v3-cinemeta.strem.io/) supplies catalog and title metadata. [BetterPosters](https://btttr.cc/) supplies vertical artwork. Browsing requires internet access and works without signing in. Playback sources come from enabled add-ons.

Home combines wide artwork, ranked cards, and traditional posters in separate shelves for What We’re Watching, Popular Today, new movies and TV shows, and popular movies and TV shows. The hero draws from live catalogs, and Home removes repeated titles across the hero and discovery shelves. Top Rated uses IMDb scores from Cinemeta, four genre shelves rotate weekly, and **Browse by Genre** opens a combined movie and TV grid for each of 14 genres. More titles load as you scroll.

Title pages use [TVmaze](https://www.tvmaze.com/) and [Wikidata](https://www.wikidata.org/) to supplement cast, character, and crew details where available.

To link your Nuvio account, open **Settings → Link Nuvio Account**, scan the QR code, and approve the connection on Nuvio’s website. Settings syncs the selected profile’s add-ons, watchlist, watch progress, and watch history from Nuvio Cloud. **Sync Now** refreshes the current profile. Playback saves the player’s actual position to the selected Nuvio profile, including when you pause or exit. Completed titles also update watch history. Home and title details use that progress for Continue Watching and Resume.

On the Siri Remote, press and hold a **Continue Watching** card to start from the beginning, mark it watched, or remove it from the shelf. Press and hold an aired episode to mark it watched or unwatched, or to mark episodes watched up to that point.

Move Nuvio Cinema to the top row of the Apple TV Home Screen to see the movies and series featured in the app’s Home carousel. Top Shelf shows each title’s artwork and synopsis. **More Info** opens the title’s details. Open Nuvio Cinema once to populate Top Shelf. Device signing must provision `group.com.nuviocinema.app` for both `com.nuviocinema.app` and `com.nuviocinema.app.TopShelf`.

When sideloading, keep the embedded `TopShelf.appex`. The app and extension both need provisioning profiles that authorize the same registered App Group. If the signer changes bundle IDs, keep the extension ID under the app’s bundle ID and use the same authorized group in both signatures. **Settings** reports when the extension is missing, the app cannot open its shared group, or the extension’s provisioning profile lacks that group. See [Apple’s App Group documentation](https://developer.apple.com/documentation/xcode/configuring-app-groups) and [entitlement diagnostics](https://developer.apple.com/documentation/bundleresources/diagnosing-issues-with-entitlements).

On a movie or episode, choose **Play** or **Resume**, then choose a source from your enabled add-ons. Direct HTTPS streams open in the original [NuvioTVOS player](https://github.com/bobsupra/NuvioTVOS/tree/735adf8859462b5beb47dbc96a51c75ded15c685), with its AetherEngine and MPVKit playback, Siri Remote seeking and previews, subtitle controls and timing, and next-episode controls. IntroDB provides skip controls when it has matching markers for the movie or episode. HTTPS provider links can open a compatible installed app. Trailers can open in YouTube.

## Build and run

Use an Apple silicon Mac with Xcode 27 or later, the tvOS SDK, Tuist 4.207.0, and Python 3.9 or later. From the cloned repository, generate the workspace. The script fetches the pinned upstream source and prepares the Cinema app and Top Shelf extension. The first build needs internet access to resolve Swift packages.

```sh
Scripts/prepare-upstream-player --generate
```

Open `.upstream-player/tvosApp/NuvioTV.xcworkspace`, select the `NuvioTV` scheme and an Apple TV simulator running tvOS 18 or later, then press **Run**. Simulator builds require an Apple silicon Mac. Run `Scripts/prepare-upstream-player` after editing Cinema sources to refresh the generated workspace’s source copies. Use `--generate` again if you add, move, or remove source files. The standalone `NuvioCinema.xcodeproj` builds the legacy playback implementation.

Build simulator updates with Xcode signing enabled so Keychain can restore the saved Nuvio session. Install over the existing app with the same bundle identifier and signing identity.

```sh
xcodebuild -workspace .upstream-player/tvosApp/NuvioTV.xcworkspace -scheme NuvioTV \
  -destination 'generic/platform=tvOS Simulator' build
```

To compile for a generic Apple TV without code signing, run this from the project directory:

```sh
xcodebuild -workspace .upstream-player/tvosApp/NuvioTV.xcworkspace -scheme NuvioTV \
  -destination 'generic/platform=tvOS' CODE_SIGNING_ALLOWED=NO build
```

Package the resulting device build with `Scripts/package-ipa PATH_TO_BUILT_APP OUTPUT_IPA`. The script adds an ad hoc signature to the app and Top Shelf extension so the sideloader can read their App Group entitlement. The sideloader still needs to sign the IPA for your Apple TV.

## Contributing

Cinema’s Swift code lives under `Sources/`, grouped by feature. Changes to the upstream playback engine live under `Scripts/Patches/` and are applied when generating the workspace. GitHub Actions builds the unsigned Release configuration for a generic Apple TV.

For UI changes, check the affected screen with a Siri Remote or the Apple TV simulator. For playback changes, include the tvOS version, player backend, and the action that triggered the issue. Remove account details and private add-on URLs before sharing logs.

## License

Nuvio Cinema is distributed under the [GNU General Public License v3.0](LICENSE). The build fetches the exact upstream source revision recorded in [the workspace preparation script](Scripts/prepare-upstream-player). Playback backports are included in [Scripts/Patches](Scripts/Patches/). The generated app bundles applicable upstream and playback dependency notices.

## Disclosures

- **AI usage.** OpenAI Codex assisted with writing, debugging, reviewing, and documenting this project.
- **NuvioTVOS code and artwork.** Nuvio Cinema incorporates the player and Top Shelf extension from [bobsupra/NuvioTVOS](https://github.com/bobsupra/NuvioTVOS) and adapts its Nuvio wordmark for the app icon. The build uses [the pinned upstream revision](https://github.com/bobsupra/NuvioTVOS/tree/735adf8859462b5beb47dbc96a51c75ded15c685) with Cinema’s integration and playback patches. Credit goes to the NuvioTVOS contributors.
