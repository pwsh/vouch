# Vouch

*Audit evidence screen captures, with the clock in the shot.*

`vouch.ps1` walks a list of web application pages and takes **real screen
captures** of each one, then assembles them into a single self-contained HTML report.
The screenshots are genuine captures of the primary display — not browser-rendered
full-page images — so the Windows taskbar and its clock are visible in every image,
which is what auditors ask for when they want to see *when* the evidence was taken.
Pages taller than one screen are captured as a series of viewport segments as the
script scrolls down. The report embeds every image as base64, so the one `.html` file
can be attached to an audit workpaper and opened anywhere with no loose image files.

## Requirements

- Windows 10 or 11.
- PowerShell 7 or later: `winget install Microsoft.PowerShell`
- Microsoft Edge (the version that ships with Windows is fine).

No modules, no DLLs, nothing to install beyond the two above. The script drives Edge
through the Chrome DevTools Protocol and captures the screen with the built-in
`System.Drawing` APIs.

## First-time setup

Most configuration pages are behind a login, so first give the script its own browser
profile and sign in:

```powershell
.\vouch.ps1 -LoginSetup
```

Edge opens with a dedicated profile at `%LOCALAPPDATA%\Vouch\EdgeProfile`.
Sign in to every application you plan to capture, complete any MFA prompts, tick
"stay signed in" where offered, then return to the console and press Enter.

Why a separate profile? Chromium 136 and later refuse to enable
`--remote-debugging-port` when the default user profile is in use — a security change
that blocks cookie theft through the debugging port. Automation therefore has to run
against a `--user-data-dir` of its own. The upside is that your everyday browsing is
untouched, and the audit logins persist in that folder, so `-LoginSetup` is normally a
one-time step. Repeat it whenever a session expires or you add a new application.

## Usage

1. Copy `captures.sample.csv` to `captures.csv` and edit it — one row per screenshot.
2. Run the script.
3. Open the report it prints at the end.

```powershell
# Default: reads captures.csv next to the script and writes
# reports\VouchReport_<date>_<time>.html next to the script, whatever the current folder
.\vouch.ps1

# Another definition file and output folder
.\vouch.ps1 -CsvPath .\q3-itgc.csv -OutputDir C:\Audit\2026-Q3

# Also keep the individual images next to the report (reports\images\)
.\vouch.ps1 -SaveImages

# Leave the browser open afterwards, e.g. to debug a selector
.\vouch.ps1 -KeepBrowserOpen

# Lossless screenshots (much larger report)
.\vouch.ps1 -ImageFormat png
```

Useful switches: `-SettleSeconds` (pause after load and after each click, default 2),
`-ScrollSettleSeconds` (pause after each scroll so lazy content can load, default 1),
`-MaxScrollSegments` (cap per page, default 30), `-NavigationTimeoutSec` (default 30),
`-JpegQuality` (default 85), `-DebugPort` (default 9222), `-FailOnWarning`,
`-LogDir` (write a log of the run to that folder), `-JsonSummary` (also write the
results as `.json` next to the report, for monitoring or scripts).
Run `Get-Help .\vouch.ps1 -Detailed` for the full list.

Relative paths passed to `-CsvPath` and `-OutputDir` resolve against the current
folder; the defaults resolve against the script's folder, so a scheduled task finds its
files without a "Start in" setting.

| Exit code | Meaning |
| --- | --- |
| `0` | Nothing failed (warnings are allowed unless `-FailOnWarning` is set). |
| `1` | The run could not start: bad CSV, Edge not found, DevTools port unavailable. |
| `2` | At least one item failed. |
| `3` | Only with `-FailOnWarning`: nothing failed, but at least one item has a warning — for example an expired session redirecting to a sign-in page. Use this for scheduled jobs so an expired login does not look like a successful run. |

## Running on a schedule

`Install-VouchSchedule.ps1` sets up a Windows scheduled task that runs the capture for
you — no Task Scheduler clicking needed:

```powershell
.\Install-VouchSchedule.ps1 -At 07:30                    # every weekday at 07:30
.\Install-VouchSchedule.ps1 -Schedule Weekly -DaysOfWeek Monday -At 06:00 `
    -CsvPath .\q3-itgc.csv -OutputDir C:\Audit\2026-Q3   # weekly, own CSV and folder
.\Install-VouchSchedule.ps1 -Schedule AtLogOn            # 3 minutes after you sign in

.\Install-VouchSchedule.ps1 -RunNow      # try it straight away
.\Install-VouchSchedule.ps1 -Status      # next/last run, result in plain words, newest report and log
.\Install-VouchSchedule.ps1 -Uninstall   # remove the task (reports, logs and logins are kept)
```

Running the installer again replaces the task with the new settings. It uses
`-Daily`, `-Weekdays` (default), `-Weekly` or `-AtLogOn`, plus `-SaveImages`,
`-ImageFormat`, `-MaxRunHours` (default 2) and `-TaskName` if you want several schedules.

What the task does for you: it runs PowerShell 7 hidden in **your** signed-in session,
starts in the script folder, writes a log of every run to `<reports>\logs\`, and passes
`-FailOnWarning` so an expired login shows up as *Last Run Result 0x3* instead of a green
tick (`-AllowWarnings` turns that off). A run missed while the PC was off starts as soon
as possible, and two runs never overlap.

**The one thing it cannot do for you:** screen captures need an unlocked desktop. At the
scheduled time you must be signed in, with the screen unlocked and the screen saver not
running — otherwise the images come out blank. If your screen locks after inactivity,
`-Schedule AtLogOn` (run shortly after you sign in) is the most dependable choice. Over
Remote Desktop, keep the session connected and not minimised. A task set to "run whether
user is logged on or not" can never work, because that session has no desktop; the
installer never sets it up that way.

Sign in once with `.\vouch.ps1 -LoginSetup` before the first scheduled run, and again
whenever `-Status` reports warnings about expired logins.

For your own unattended setups, `vouch.ps1 -LogDir <folder>` writes the same run log.

## CSV reference

Header: `Name,Url,Steps,ScrollFullPage,Notes`

| Column | Required | Meaning |
| --- | --- | --- |
| `Name` | yes | Short label for the evidence item. Shown in the report and used in image file names. |
| `Url` | yes | Page to capture. Must start with `http://` or `https://`. |
| `Steps` | no | Semicolon-separated actions performed after the page loads, before the screenshot. |
| `ScrollFullPage` | no | `Y` to scroll the whole page and capture every screenful. Blank or `N` captures one screen. Also accepts `Yes`/`No`, `True`/`False`, `1`/`0`. |
| `Notes` | no | Free text reproduced in the report — the control reference, what the reviewer should look at, and so on. |

Fields containing a comma must be quoted, as in any CSV. Excel does this for you.
Completely blank rows (such as the `,,,,` rows Excel leaves behind) are ignored.

### Step grammar

| Step | Effect |
| --- | --- |
| `click:<css selector>` | Clicks the first element matching the CSS selector. |
| `clicktext:<visible text>` | Clicks the link, button or tab whose visible text matches. Case-insensitive. Only elements actually shown on the page count. An exact match wins; otherwise the closest partial match (the one with the shortest text). A partial match never picks a log-out / sign-out control, so `clicktext:Log` cannot end the session — write `clicktext:Log out` if you really mean it. |
| `wait:<seconds>` | Pauses, for pages that load data after rendering. `2.5` and `2,5` both work. |

When a `click:` or `clicktext:` step opens another page, the script waits for that page
to finish loading (up to `-NavigationTimeoutSec`) before the next step or screenshot.

Combine steps with `;`, for example:

```
click:#settings-tab ; clicktext:Audit Log ; wait:3
```

Prefer `clicktext:` — it survives redesigns better than a selector. Use `click:` when
the target has no distinctive text or the same text appears several times.

**Finding a CSS selector:** open the page in Edge, press `F12`, click the arrow icon at
the top left of DevTools (or press `Ctrl+Shift+C`), and click the element on the page.
In the Elements panel, right-click the highlighted line and choose
**Copy → Copy selector**. Paste it after `click:`. Shorten it if you can — `#tab-users`
is far more durable than a long `body > div:nth-child(3) > ...` chain. A quick way to
verify: in the DevTools Console, run `document.querySelector('#tab-users')` and confirm
it returns the element rather than `null`.

## How failures appear

Every row gets a status badge in the summary table and in its own section. One row's
problem never stops the run — the script always continues to the next row.

| Badge | Meaning |
| --- | --- |
| **OK** (green) | Page loaded, all steps ran, screenshots taken. |
| **WARNING** (amber) | Evidence was captured but needs a look. Typically the final URL is on a different origin than requested ("redirected to … — possible login required"), the page landed on a sign-in page of the same site ("redirected to a sign-in page — the session has probably expired"), a step failed (bad selector, text not found, a page it opened did not load in time), the page did not finish loading in time, the Edge window could not be brought to the front, or the page was truncated at the segment cap. |
| **FAILED** (red) | Either the page could not be reached at all (`net::ERR_NAME_NOT_RESOLVED`, connection refused, or the page did not respond within `-NavigationTimeoutSec` — no screenshot is possible in these cases), or the server returned HTTP 400 or higher. HTTP errors are still captured: the error page is itself evidence. When the server sends an error with an empty body, Edge's own error page is captured instead. |

Each section records the requested URL, the URL actually reached, the HTTP status, the
outcome of every step and the exact local timestamp of each screenshot, so a reviewer
can tell "the page redirected to a login screen" apart from "the setting really is off".
A redirect warning almost always means the session for that application expired.

## Tips

- **Do not lock the workstation or start a screensaver while a run is in progress.**
  Screen captures need a visible desktop; a locked session produces black or blank
  images. Same for RDP — minimising or disconnecting a remote session stops the desktop
  from rendering. Start the run and leave the machine alone.
- Do not use the mouse or keyboard during the run either; a window brought to the front
  or a popup notification ends up in the evidence.
- **Multi-monitor:** only the primary display is captured. Keep Edge on the primary
  monitor; the script maximises it there before each shot.
- **Report size:** JPEG at quality 85 costs roughly 200–400 KB per screenshot, so a
  40-screenshot report lands around 10–15 MB, which is fine to attach to a workpaper.
  `-ImageFormat png` is lossless and typically 4–8x larger; use it only when fine text
  must be pixel-perfect. Add `-SaveImages` if you also need the images as separate files.
- Long tables get one screenshot per screenful. Filter or page down the list first if
  you only need part of it, or raise `-MaxScrollSegments` if 30 screens is not enough.
- Do a dry run of a new CSV against one or two rows before capturing a full set — it is
  quicker to fix a selector than to redo a 60-page run.

## Troubleshooting

**"Edge is already running with the audit profile … but without the DevTools port"** —
an ordinary Edge window still uses the audit profile, usually the one opened by
`-LoginSetup`. Close every window of it and rerun. (`-LoginSetup` closes its windows
itself when you press Enter and warns you if any are left.)

**"Edge did not open its DevTools endpoint on port 9222"** — something else holds the
port. Pick another port with `-DebugPort 9333`. If a debugging-enabled Edge is already
listening on the port, the script attaches to it instead of launching a new one and
notes this in the report. The Edge the script launches is closed at the end of every run
(unless `-KeepBrowserOpen`), so the debugging port does not stay open.

**"Microsoft Edge (msedge.exe) was not found"** — Edge is not installed or not
registered. Install it, or check
`HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe`.

**Blank, black or wrongly-cropped screenshots** — the session was locked, disconnected
or the screensaver started during the run. Rerun with the desktop visible. If images
look scaled or cut off on a high-DPI display, confirm you are running PowerShell 7
directly on the console rather than inside a tool that hosts it in a DPI-unaware process.

**Everything redirects to a login page** — the stored session expired. Run
`.\vouch.ps1 -LoginSetup`, sign in again, and rerun the capture.

**A step reports "no element matched"** — the selector or the visible text changed, or
the element had not rendered yet. Add `wait:3` before the step, or rerun with
`-KeepBrowserOpen` and try the selector in the DevTools Console.

**PowerShell refuses to run the script** — it is unsigned, so either unblock it once
with `Unblock-File .\vouch.ps1` or start it with
`pwsh -ExecutionPolicy Bypass -File .\vouch.ps1`.

## Tests

The `tests` folder holds a Pester suite: unit tests for the CSV parsing, report
generation and helpers, and integration tests that drive a **headless** Edge (throwaway
profile, no window, your own profiles untouched) against a local test server, including
an end-to-end run of the capture loop with only window focus and screen capture mocked.

```powershell
Install-Module Pester -Scope CurrentUser -MinimumVersion 5.0   # once
pwsh .\tests\Invoke-Tests.ps1              # everything (about 1 minute)
pwsh .\tests\Invoke-Tests.ps1 -UnitOnly    # no browser needed
```

Tests tagged `KnownIssue` document bugs that are not fixed yet and are expected to fail;
`-ExcludeKnownIssues` leaves them out. `-ResultPath results.xml` writes NUnit XML for CI.

### Live test against public websites

`tests\live\Invoke-LiveTest.ps1` runs the real thing: Edge opens maximised on this
desktop and captures ten public pages listed in `tests\live\public-sites.csv` — a plain
page, a long Wikipedia article in scroll segments, click steps that open other pages, a
404 with and without a body, an http-to-https upgrade, a failing step and an unreachable
host. Each row carries its expected status, screenshot count and final URL, and the
runner checks them, plus: every screenshot exists at full screen size and is not blank,
the taskbar strip is present, the exit code is right, and Edge is gone afterwards.

```powershell
pwsh .\tests\live\Invoke-LiveTest.ps1                 # about 1 minute; hands off the keyboard and mouse
pwsh .\tests\live\Invoke-LiveTest.ps1 -ViaScheduler   # same, through a temporary scheduled task
```

It takes over the screen, needs internet access, and uses its own throwaway Edge profile
and port (9333), so the audit profile is never touched. Results, the report and the
images land in `tests\live\output\<date>` (git-ignored). Public sites change, so an
unexpected result can mean the site moved rather than that Vouch broke — look at the
screenshot before concluding either way.
