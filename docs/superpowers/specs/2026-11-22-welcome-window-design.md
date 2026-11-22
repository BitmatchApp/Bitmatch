# Welcome window (one-time greeting) — design

Date: 2026-11-22

## Intent

Greet each person once with a short, personal note from the maintainer: why
BitMatch exists, a request to try it on non-essential footage first, where to
report bugs, and an invitation to star the repo so others can find it.
BitMatch's category runs on trust; a human introduction earns some of it and
may convert quiet Sparkle users into GitHub stars and issue reporters.

## Goals

- Appears exactly once per Mac user account, whether the person installed
  fresh or arrived by Sparkle update. Never again after dismissal.
- Reopenable on purpose from Help, without touching the "seen" flag.
- Friendly tone. Not a disclaimer, not an onboarding wizard.

## Non-goals / anti-goals

- No "don't show again" checkbox (implies it may return).
- No blocking of the main window or of transfers.
- No analytics, no network calls beyond opening the GitHub URL on request.
- No settings sprawl: nothing in Preferences.

## Constraints

- Feature freeze (2026-09-27): small, UI-only, no engine changes.
- The app delegate identifies the main content window as "not an NSPanel,
  can become main, has a content view controller". The welcome window must
  not match, or Dock/menu-bar focusing and transfer-exit guards misfire.
- Dark appearance like the rest of the app; macOS 15.5+.

## Approaches considered

1. A separate window carrying a SwiftUI view (chosen). Native look, holds
   the icon and rich copy, independent of the main window. Built as an
   `NSPanel` with an `NSHostingView` rather than a SwiftUI `Window` scene:
   a scene gives no control over `canBecomeMain`, and the app delegate
   already excludes panels from its content-window search.
2. Sheet over the main window. Reads as a nag and blocks the content view.
3. `NSAlert`. Cannot carry the icon and copy well; feels like an error.

## Decided

- Window: an `NSPanel` (titled, closable, not resizable, not floating,
  does not hide on deactivate), about 440x520, dark appearance, owned by a
  `WelcomeWindowController` in the macOS app target. Being a panel, the app
  delegate's content-window logic ignores it.
- Content, top to bottom: app icon (NSApp.applicationIconImage), title
  "Welcome to BitMatch 👋", copy (below), then buttons "Star on GitHub"
  (opens https://github.com/BitmatchApp/Bitmatch) and "Close" (default).
- Copy (about 90 words):

  > BitMatch is a passion project. I'm a working film professional and I
  > wanted reliable, verified card backups to be free for everyone.
  >
  > It's a one-person project, and I can't test every camera, card, reader
  > and drive out there. Before trusting it with real footage, please try it
  > on non-essential files first, and keep your cards until you've confirmed
  > your backups.
  >
  > Found a bug or have an idea? Open an issue on GitHub. Want to contribute?
  > Please do. And if BitMatch is useful to you, a star helps other
  > filmmakers find it.
  >
  > Thanks for giving it a shot! 👋 Mike

- Seen flag: `WelcomeGreeting` (small type in the app target) owns the
  UserDefaults key `BitMatchWelcomeShown` with injectable defaults for
  tests. Marked seen when the window closes by any route (either button or
  the red close button), not when it opens.
- Launch rule: after the main window appears, wait ~0.5 s; show if the flag
  is unset and no operation or queue is running. If a transfer is already
  running (card-insert auto-queue), skip this launch and try next launch.
- Help menu: `CommandGroup(replacing: .help)` adds "Welcome to BitMatch"
  (opens the window, does not reset the flag) and "BitMatch on GitHub".
- Tests: pure logic in `WelcomeGreeting` (unset → show; set → never;
  transfer running → defer without setting) under BitMatchTests.

## Left to the builder

Exact spacing and typography, button order per HIG (default action right),
and how the window is centered on the main screen.
