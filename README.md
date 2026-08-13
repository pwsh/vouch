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
# Default: reads .\captures.csv, writes .\reports\VouchReport_<date>_<time>.html
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
`-JpegQuality` (default 85), `-DebugPort` (default 9222).
Run `Get-Help .\vouch.ps1 -Detailed` for the full list.

Exit code is `0` when nothing failed and `2` when at least one item failed, so the
script can be wired into a scheduled job.

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

### Step grammar

| Step | Effect |
| --- | --- |
| `click:<css selector>` | Clicks the first element matching the CSS selector. |
| `clicktext:<visible text>` | Clicks the link, button or tab whose visible text matches (exact match first, otherwise the first partial match). Case-insensitive. |
| `wait:<seconds>` | Pauses, for pages that load data after rendering. |

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
| **WARNING** (amber) | Evidence was captured but needs a look. Typically the final URL is on a different origin than requested ("redirected to … — possible login required"), a step failed (bad selector, text not found), the page did not finish loading in time, or the page was truncated at the segment cap. |
| **FAILED** (red) | Either the page could not be reached at all (`net::ERR_NAME_NOT_RESOLVED`, connection refused — no screenshot is possible in this case), or the server returned HTTP 400 or higher. HTTP errors are still captured: the error page is itself evidence. |

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

**"Edge did not open its DevTools endpoint on port 9222"** — an ordinary Edge window is
already using the audit profile, or something else holds the port. Close Edge windows
that were started with the audit profile and retry, or pick another port with
`-DebugPort 9333`. If a debugging-enabled Edge is already listening on the port, the
script attaches to it instead of launching a new one and notes this in the report.

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
