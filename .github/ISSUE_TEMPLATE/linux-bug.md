---
name: Linux bug report
about: Something doesn't work on Linux
title: "[linux] "
labels: linux, bug
---

<!--
Linux support is in beta — the maintainer ships from macOS and can't test
every distro/DE combination. Detailed bug reports are how we converge.
The `gh-wallpaper diagnose` command emits everything we need to triage; please
paste its full output below.
-->

### What I ran
<!-- The exact command(s) and any flags. -->


### What I expected


### What happened
<!-- Errors, missing wallpaper update, weird image, etc. -->


### `gh-wallpaper diagnose` output

```
<!-- Paste the full output of: gh-wallpaper diagnose -->
```

### `journalctl` tail (if the systemd unit is involved)

```
<!-- Paste the output of: journalctl --user-unit=gh-wallpaper.service -n 50 --no-pager -->
```

### Anything else worth knowing
<!-- Multi-monitor setup? Custom theme? Specific distro version? Wayland-fragile compositor? -->
