# Changelog

## 1.1.0

- Usage-limit resets. Claude and Codex now give free resets; each account card
  shows how many you have and when the next one expires, and the account's
  settings list them all. Ration only shows resets — use them on the
  provider's usage page.
- Ration tells you (notification and menu-bar drop) when a new reset arrives,
  and again when one is about to expire. How early is set per provider in
  Settings → Alerts (1 day by default).
- Warm-up is now on by default for newly added Claude accounts. Existing
  accounts keep their setting; turn it off per account under Auto-start 5h
  window.
- While a Ration window is open (sign-in, Settings, History), Ration shows
  in the Dock and in Cmd-Tab, so you can switch to your mail for a sign-in
  link and come back. It goes back to menu-bar-only when you close it.

## 1.0.1

- A dismissed attention drop now comes back right at launch after a limit
  reset that happened while Ration was closed, even if you have not allowed
  notifications. Before, it stayed hidden until the first refresh.

## 1.0.0

First public release.

- Live usage meters for Claude (5-hour, weekly and Fable weekly on Max plans),
  ChatGPT / Codex (5-hour and weekly) and Cursor (usage-based spend for the
  current billing period), read from your own signed-in sessions.
- Menu-bar rings: one ring per account in the provider's colour, with a green
  dot on the account currently in use.
- Reset countdowns and a soonest-reset summary in the popover.
- Alerts at thresholds you choose, per provider and window, delivered as a
  notification, as an attention drop under the menu bar, or both. Fires once
  per crossing and re-arms when the window resets. Privacy mode keeps labels
  and exact usage out of notifications.
- Usage history with an all-accounts overlay, hour-of-day heatmap and
  burn-rate projection; billing-cycle utilisation since your renewal day.
- Several accounts per provider, grouped, with pause and resume, optional
  sort by soonest reset, and per-account labels.
- Claude warm-up: optionally start the 5-hour window the moment it resets,
  inhibited during quiet hours and holidays and when the weekly allowance is
  already spent.
- First-run setup guide, launch at login, ⌥⌘U to open the window anywhere.
- Universal build, Developer ID signed and notarized. Requires macOS 26.
