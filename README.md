# Spark install check

Downloads the Spark desktop app from get-spark.io and installs it on clean
GitHub-hosted machines, the way a customer would, then checks it opens, shows
its window and keeps running.

| Platform | Machines |
|---|---|
| macOS, Apple Silicon | macOS 26, macOS 15 |
| macOS, Intel | macOS 26, macOS 15 |
| Windows, x64 | Windows Server 2025, Windows Server 2022 |
| Windows, ARM | Windows 11 |

Each machine checks: the download, Gatekeeper and notarisation (Mac) or the
code signature (Windows), the install, the bundled tools (yt-dlp, ffmpeg,
ffprobe, QuickJS), that Spark opens with a window, and that it is still
running a minute and a half later with no crash report. Screenshots are kept
with each run. A warning (WARN) is worth fixing but does not stop customers
installing; only a FAIL fails the run.

Runs every Monday, on request (Actions, "Spark install check", Run workflow,
optionally with the address of a test build), and when a release sends a
`spark-release` repository dispatch.

Test machines never count as real installs: downloads use curl, which the
site's download counter treats as a script, and get-spark.io is blocked on the
machine before Spark is opened.
