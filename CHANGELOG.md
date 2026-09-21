# Changelog

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
