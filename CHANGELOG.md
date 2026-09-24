# Changelog

## 1.3.0

- Which account next: when the account you're using reaches your warning
  threshold and another account from the same provider has clearly more
  room left, Ration says so — in the popover header ("Switch Claude to
  Personal · 85% of week left"), in that limit's notification, and in the
  alerts panel.
  Fable counts toward the choice only if you actually use it.
- Plans: Ration reads each account's plan (Claude Pro / Max 5x / Max 20x,
  ChatGPT Plus / Pro 5x / Pro 20x) and compares real remaining capacity, so
  25% of a 20x plan isn't mistaken for less room than 100% of a 5x plan. When
  the plan can't be read, Ration asks after sign-in, together with the billing
  day; both can be changed in the account's settings.
- Focus layout: switch between Standard and Focus from the popover header.
  Focus shows the subscription you're using as one big number, the other
  accounts in use, accounts that are nearly spent, and where to go next;
  click any account to see it up close.
- Feature switches: Settings → General → Features turns Resets, Switch
  suggestions, Claude warm-up and In-use detection on or off. All are on by
  default.
- Limit names (5H, WK, Fable) are shown as small tags everywhere, so a reset
  like "5H 22m" can't be misread; the popover header shows the Ration mark.

## 1.2.1

- Ration builds from source with Xcode 26.6 again. No change to how the app
  works.

## 1.2.0

- Light and dark themes. Settings → General → Appearance: System (default),
  Light or Dark. If your Mac is in light mode, Ration now opens light —
  pick Dark to keep the old look.
- Calmer colours: the neon cyan, gold and green are toned down, and every
  text colour now meets WCAG AA contrast in both themes.
- Larger text: every size Ration sets is 2 pt bigger. Native macOS controls
  in Settings keep the system size.
- ChatGPT has its own colour, OpenAI green. The "fine" usage colour is now a
  quiet slate, so no provider shares a colour with a status.
- The account you're using stands out in both themes.
- The popover header tells the truth about your data: LIVE when every account
  is current, STALE · N when some aren't, OFFLINE when none are.
- Notifications: if Ration has never asked for permission, it now offers
  Allow Notifications instead of pointing you at System Settings. Allowing or
  revoking notifications takes effect without restarting Ration.
- Keyboard: with the popover open, ⌘R refreshes, ⌘, opens Settings, ⌘Q quits
  and ⌘D dismisses the alerts panel.
- Accessibility: VoiceOver announces the alerts panel and reads durations and
  limit names in full; Increase Contrast strengthens lines and faint text;
  click a reset countdown to see the exact reset time.
- Settings: limit names and headers no longer wrap, threshold fields look
  editable, and the reset-expiry warning label fits.

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
