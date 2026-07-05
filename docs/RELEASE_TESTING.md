# Release smoke checklist

A 10-step manual smoke test to walk through before tagging a release.
Half a page; takes about 5 minutes per release. Skipping it before a
release is the most likely way to ship something obviously broken.

This corresponds to the checklist in `SPEC.md` §17.

## Prerequisites

- A Mac running **macOS 14 (Sonoma) or newer**.
- A **fresh user account** (or at minimum a user that has never installed
  `gh-wallpaper`). This is what shakes out "works on my machine"
  bugs — leftover state from a previous install masks regressions in the
  setup wizard, the launchd registration, and the previous-wallpaper
  capture flow.
- The release candidate available via the Homebrew tap
  (`brew install Numbatt/tap/gh-wallpaper`). For pre-tap dry-runs,
  install the local formula: `brew install --HEAD ./Formula/gh-wallpaper.rb`.
- A real, public GitHub username with at least a few visible
  contributions in the trailing year. Don't test with an empty profile —
  you want to *see* something render.
- An external display you can plug in and unplug, for the multi-monitor
  step.
- Wi-Fi you can toggle off and back on, for the network-drop step.

## Checklist

- [ ] **1. Install via Homebrew on a clean account.** Run
      `brew install Numbatt/tap/gh-wallpaper` (or the local-formula
      equivalent). Verify `gh-wallpaper` is on `PATH` and launches
      without a Gatekeeper prompt or "this app is damaged" warning.
- [ ] **2. Run the setup wizard with a real username.** Run
      `gh-wallpaper` with no arguments. Step through every wizard
      prompt: username, theme, displays, capture-previous, preview,
      activate. Confirm validation rejects an obviously bogus
      username (e.g. `this-account-does-not-exist-xyz`).
- [ ] **3. Verify the wallpaper renders and is set on the main display.**
      The poster should appear on the main display within a few seconds
      of finishing the wizard. Headline reads `DESIGN. BUILD. SHIP.`,
      heatmap renders the user's actual contribution data, theme
      matches the wizard selection.
- [ ] **4. Switch theme via `gh-wallpaper theme <other>` and verify the
      wallpaper updates.** Pick a theme different from the wizard
      selection (e.g. `paper` or `midnight`). The wallpaper should
      re-render and re-set within seconds — no restart, no re-login.
- [ ] **4a. Open the visual theme editor and create a custom theme.**
      Run `gh-wallpaper my-test` (an unknown name). It prompts
      `Create a custom theme called 'my-test'? [y/N]` — answer `y`.
      The window opens with seven color pickers and a live preview. Drag a color well —
      the preview should update within ~250ms. Click "Add image…"
      and pick a PNG/JPEG; preview should show the photo behind
      the heatmap with the dim overlay. Click **Save & apply 'my-test'**.
      Wallpaper switches to the new theme. Run
      `gh-wallpaper themes` and confirm `my-test` is listed.
- [ ] **4b. Fork a built-in theme via `theme <id> --edit`.**
      Run `gh-wallpaper theme dracula --edit`. Editor opens seeded
      from dracula, name field empty (placeholder "my-dracula"),
      Save buttons disabled. Type "my-dracula" — Save buttons
      enable and read "Save as custom theme 'my-dracula'" /
      "Save & apply 'my-dracula'". Click Save & apply, confirm
      wallpaper changes.
- [ ] **4c. Verify CRUD on `themes`.**
      `gh-wallpaper themes export dracula | sed 's/dracula/imported-dracula/g' | gh-wallpaper themes import`
      should round-trip. Then
      `gh-wallpaper themes delete imported-dracula` removes it.
      `gh-wallpaper themes delete dracula` should refuse
      ("built-ins are immutable").
- [ ] **5. Plug in an external display and verify a per-display PNG
      appears.** Connect an external monitor. Within the debounce
      window (~30s), the daemon should render a separate PNG sized to
      that display's native resolution and set it as the wallpaper on
      that screen. Confirm
      `~/Library/Application Support/gh-wallpaper/wallpaper-<UUID>.png`
      exists for both displays.
- [ ] **6. Sleep the Mac, wake it, verify the wallpaper refreshes within
      the debounce window.** Close the lid (or `pmset sleepnow`), wait
      a few seconds, wake. Within ~30s of wake, check
      `~/Library/Logs/gh-wallpaper/agent.log` for a refresh tick
      triggered by `NSWorkspace.didWakeNotification`.
- [ ] **7. Disable Wi-Fi, verify the daemon doesn't crash and resumes on
      reconnect.** Turn Wi-Fi off. Wait 2–3 minutes. Confirm the
      daemon is still running (`launchctl list | grep gh-wallpaper`)
      and the log shows a "network unreachable; pausing" entry rather
      than a crash. Re-enable Wi-Fi; the next log entry should be an
      immediate refresh.
- [ ] **8. Run `gh-wallpaper diagnose` and verify all expected fields
      are present.** Output should include: install state, last
      refresh timestamp, last error (if any), parser status, configured
      theme, configured displays, log path, daemon PID. No fields
      should be blank or `<unknown>`.
- [ ] **9. Run `gh-wallpaper uninstall` and verify the previous
      wallpaper is restored** (or the macOS Wallpaper settings deep-link
      opens for a Dynamic Desktop). For static-image previous
      wallpapers, the original image should be back on screen. For
      Dynamic Desktops, Settings.app should open to the Wallpaper pane
      with a clear console message explaining why we couldn't restore
      automatically.
- [ ] **10. Confirm `~/Library/Application Support/gh-wallpaper/` and
      the launchd plist are gone.** After uninstall, all of these
      should be absent:
      - `~/Library/Application Support/gh-wallpaper/`
      - `~/Library/Logs/gh-wallpaper/`
      - `~/Library/LaunchAgents/dev.numbatt.gh-wallpaper.plist`
      - The `gh-wallpaper` process should no longer appear in
        `launchctl list`.

## When something fails

Don't ship. File an issue with the failing step number, the
`gh-wallpaper diagnose` output, and the relevant tail of
`~/Library/Logs/gh-wallpaper/agent.log`. Cut a fix, repeat the full
checklist (not just the failing step — fixes can regress earlier
steps), then tag.
