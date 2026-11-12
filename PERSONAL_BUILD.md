# Driftwood: personal build and TestFlight

## Uploading from GitHub (no Mac needed)

The Apple keys come from `Coral-coder/Dev_deploy_setup` (Actions → **Set up app repo**, repos =
`BookPlayer`). `.github/workflows/ios-testflight.yml` builds on GitHub's Xcode 27 runner, and
`.github/scripts/pre-build.sh` writes the two xcconfig files there with your team and
`com.lightwave.driftwood`.

- Create the app once in App Store Connect (Apps → + → New App, name **Driftwood**, bundle ID
  `com.lightwave.driftwood`, SKU `driftwood`). Apple's API can't create it.
- Then push to `develop` with `*u` in the commit's first line (or Actions → **iOS TestFlight** →
  Run workflow). `*b` only archives, as a check.

The steps below are for building on your own Mac instead.

This fork builds BookPlayer as **Driftwood**, a personal build:

- **No subscriptions or tips.** The Profile tab (sign-in, cloud sync, plans), the Pro banner, the tip jar
  and the plans/tips onboarding are gone. Every perk the free tier used to lock (themes, app icons and
  the rest of "Plus") is unlocked. The switch is `AppEnvironment.isPersonalBuild` in
  `Shared/Utils/AppEnvironment.swift`.
- **Audiobooks on the Apple Watch without the cloud.** On the iPhone, long-press a book in the library
  (or select it and open the "…" menu) and tap **Send to Apple Watch**. The file goes over in the
  background, even when the watch app is closed, and shows up in the watch's library. Swipe a book on the
  watch to remove it. From the bottom of the watch library, **Control iPhone** is the old remote control
  for what's playing on the phone.

No secrets are needed. The real BookPlayer keys (RevenueCat, Sentry, the BookPlayer server) belong to
BookPlayer's developers and stay with them. This build leaves those values as placeholders and works
without them. You only fill in your own Apple Team ID and bundle ID.

---

## What you need

- A Mac with **Xcode 27.1** (from the Mac App Store or developer.apple.com/download). Older Xcode
  versions can't build this project.
- Your paid Apple Developer Program membership.
- Your iPhone and Apple Watch, signed in to the same Apple Account as TestFlight.

## 1. Get your Team ID

1. Go to <https://developer.apple.com/account> and sign in.
2. Open **Membership details**. Copy the **Team ID** (10 characters, like `AB12CD34EF`).

## 2. Pick your bundle ID

It must be unique and in reverse-domain form. Example used below: `com.yourname.driftwoodlisten`
(lowercase letters, numbers, dots, no spaces). The extensions get IDs that start with it
(`….watchkitapp`, `….watchkitapp.widgets`, `….BookPlayerWidgetUI`, `….BookPlayerShareExtension`) and
the shared App Group is `group.com.yourname.driftwoodlisten`. Xcode creates all of them for you
in step 5.

## 3. Get the code onto the Mac

```sh
git clone https://github.com/Coral-coder/BookPlayer.git
cd BookPlayer
git checkout claude/ecstatic-darwin-pi8l3p   # or develop, once the pull request is merged
```

## 4. Fill in the two config files

Both files are git-ignored, so your values never get committed.

```sh
cp BuildConfiguration/Debug.template.xcconfig BuildConfiguration/Debug.xcconfig
```

In **both** `BuildConfiguration/Debug.xcconfig` and `BuildConfiguration/Release.xcconfig`, change only
these two lines and leave everything else as it is (the `replace.me` placeholders are fine):

```
DEVELOPMENT_TEAM = AB12CD34EF
BP_BUNDLE_IDENTIFIER = com.yourname.driftwoodlisten
```

Keep `BP_ENTITLEMENTS = BookPlayer-NoCarPlay`. CarPlay needs a separate approval from Apple.

## 5. Let Xcode handle signing

1. Open `BookPlayer.xcodeproj` and wait for the Swift packages to finish resolving (status bar at the top).
2. Select the blue **BookPlayer** project in the left sidebar. For each of these targets, open
   **Signing & Capabilities** and tick **Automatically manage signing**, with **Team** set to your team:
   `BookPlayer`, `BookPlayerWatch`, `BookPlayerWidgetsPhone`, `BookPlayerWidgetsWatch`,
   `BookPlayerShareExtension`.
3. Xcode registers the App IDs, the App Group and the iCloud container itself. If a target shows a red
   error about a capability, click **Try Again**. If it's still red, remove that capability with the small
   trash icon and add it back with **+ Capability**.

## 6. Test on your own devices first

1. Connect your iPhone, choose the **BookPlayer** scheme and your iPhone as the destination, and press
   **Run** (⌘R). Turn on Developer Mode on the iPhone if it asks.
2. Import an audiobook (Library → + → Import files).
3. Install the watch app: open the **Watch** app on the iPhone → My Watch → find **Driftwood** → Install.
4. In the iPhone app, long-press the book → **Send to Apple Watch**. Keep the watch on its charger or
   near the phone. Large books can take a while (Bluetooth/Wi-Fi between the devices is slow). When it's
   done, the book appears in the watch app.

## 7. Create the app in App Store Connect

1. Go to <https://appstoreconnect.apple.com> → **Apps** → **+** → **New App**.
2. Platform: iOS. Name: **Driftwood** (if it's taken, try "Driftwood Audio" or similar.
   The name on your home screen stays "Driftwood"). Language: English. Bundle ID: pick the one from
   step 2 (it appears after step 5). SKU: anything, such as `driftwoodlisten`. User Access: Full Access.

## 8. Archive and upload

1. In Xcode, set the destination to **Any iOS Device (arm64)**.
2. **Product → Archive**. When the Organizer opens, select the archive → **Distribute App** →
   **TestFlight Internal Only** (or **App Store Connect**) → **Distribute**. The watch app is uploaded
   inside the iPhone app.
3. To upload again later, raise the build number first: project → `BookPlayer` target → General →
   **Build** (for example 1 → 2). Each upload needs a new build number.

The app already declares that it uses no non-exempt encryption, so no export-compliance question
should block the build.

## 9. TestFlight

1. In App Store Connect → your app → **TestFlight**. After processing (usually 10–30 minutes) the build
   appears.
2. **Internal Testing** → **+** → create a group, add yourself (your Apple Account must be a user on
   your developer team) and add the build. Internal testing needs no Apple review.
3. Install the **TestFlight** app on the iPhone and accept the invite. Install from there; the watch app
   installs through the Watch app as in step 6.

For **external** testers (people outside your team), Apple reviews the build first. Before that, replace
the app icon (`BookPlayer/Assets.xcassets/AppIcon…`) with your own: the current one is BookPlayer's
logo, and a build that looks like another developer's app can be rejected.

## Good to know

- BookPlayer is GPL-3.0. Sharing builds of it with others means sharing your changes' source too. This
  fork on GitHub already does that.
- Hardcover sign-in won't work unless you register your own Hardcover OAuth app and put its client ID in
  `BP_HARDCOVER_CLIENT_ID`. Everything else (playback, sleep timer, bookmarks, Jellyfin and
  AudiobookShelf, iCloud backup of files) works without any keys.
