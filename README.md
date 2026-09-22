# FastDownloader for iOS

FastDownloader is a sideload-friendly iPhone download manager with an embedded WebKit browser and a background URLSession download engine.

## Current MVP features

- Native SwiftUI interface.
- Embedded WKWebView browser.
- Multiple persistent in-memory browser tabs.
- Pop-up pages open in separate tabs so the original download page stays available.
- Automatic interception of navigation actions marked as downloads.
- Automatic interception of attachment responses and MIME types WebKit cannot display.
- Long-press a link and choose Download Link.
- Browser session hand-off: matching cookies, Referer and User-Agent are copied to the download request.
- Background URLSession transfers.
- Pause and resume using resume data when iOS/server supports it.
- Retry from the original URL and preserved request headers.
- Completed files are saved under Documents/Downloads and exposed through the iOS Files app.
- Optional streaming SHA-256 calculation after download.
- GitHub Actions builds and tests the app and produces an unsigned IPA suitable for signing with Feather.

## Install

1. Open the latest successful GitHub Actions run.
2. Download the FastDownloader-unsigned-IPA artifact.
3. Extract the Actions artifact ZIP if GitHub wraps it in a ZIP.
4. Import FastDownloader-unsigned.ipa into Feather.
5. Sign with your own certificate and provisioning profile.
6. Install on the iPhone.

## Important iOS behavior

Background URLSession can continue transfers while the app is suspended or terminated by the system. If the user manually force-quits the app from the app switcher, iOS cancels background transfers.

## Planned work after device testing

- Adaptive segmented/range downloading for servers where multiple connections are actually faster.
- Smarter handling of temporary/expired links.
- Per-site popup and ad rules.
- Download speed and ETA calculation.
- More browser controls and download history tooling.
