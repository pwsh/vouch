# Getting started with Vouch — a step-by-step guide

This guide is for people who need audit evidence screenshots and are not programmers.
It walks you through everything once, in order, and tells you what you should see at each
step. You do everything in the **Vouch Designer**, a window where you point and click;
typing commands is optional. Setting up takes about 30 minutes the first time; after
that, taking a full set of evidence is one button, or nothing at all if you schedule it.

If something here does not match what you see, jump to
[When something goes wrong](#when-something-goes-wrong).

**Contents**

1. [What Vouch does and what you get](#1-what-vouch-does-and-what-you-get)
2. [What you need](#2-what-you-need)
3. [Install PowerShell 7](#3-install-powershell-7-once)
4. [Get Vouch](#4-get-vouch-once)
5. [Start the Designer](#5-start-the-designer)
6. [Sign in to your sites](#6-sign-in-to-your-sites-once)
7. [Add your first page](#7-add-your-first-page)
8. [Tell Vouch what to capture](#8-tell-vouch-what-to-capture)
9. [Test one page](#9-test-one-page)
10. [Fill in the report details](#10-fill-in-the-report-details)
11. [Choose where and how the evidence is saved](#11-choose-where-and-how-the-evidence-is-saved)
12. [Save your configuration](#12-save-your-configuration)
13. [Run everything](#13-run-everything)
14. [Read the report and the capture log](#14-read-the-report-and-the-capture-log)
15. [Share the evidence](#15-share-the-evidence)
16. [Check a report later](#16-check-a-report-later)
17. [Run without the Designer](#17-run-without-the-designer)
18. [Run it on a schedule](#18-run-it-on-a-schedule-optional)
19. [When a page needs more time or your input](#19-when-a-page-needs-more-time-or-your-input)
20. [Things Vouch cannot do](#20-things-vouch-cannot-do)
21. [If you already use a CSV file](#21-if-you-already-use-a-csv-file)
22. [When something goes wrong](#when-something-goes-wrong)
23. [Quick reference card](#quick-reference-card)
24. [Words used in this guide](#words-used-in-this-guide)

---

## 1. What Vouch does and what you get

You give Vouch a list of web pages — for example the password-policy page of an
application, or its list of administrator accounts. Vouch then:

- opens each page in Microsoft Edge, one after another, by itself;
- clicks through to the right tab or section if you tell it to;
- takes a **real screenshot of your whole screen**, so the Windows clock and date at the
  bottom right are in every picture — that is what auditors usually want to see (you can
  also choose the Edge window only, or the page content only);
- scrolls down long pages and takes one screenshot per screenful;
- puts everything into **one report file** that you can open in any browser, print to
  PDF, or attach to a workpaper.

It also records exactly when and where each screenshot was taken, and gives every
screenshot a unique fingerprint (a "hash") so anyone can check later that the pictures
have not been edited.

**What you get after a run**, in the output folder (normally `reports`):

| File | What it is |
| --- | --- |
| `VouchReport_<date>_<time>.html` | **The report.** All screenshots, page by page, with the time of each and their fingerprints. Opens in any browser. |
| `VouchReport_<date>_<time>.log` | **The capture log.** A plain-text, time-stamped account of the run, written line by line while it happens: each page, each click, each question and answer, each picture with its fingerprint, each warning. On by default. |
| `images\VouchReport_<date>_<time>\` | *Optional.* Every screenshot as a picture file, with a `SHA256SUMS` list of their fingerprints. |
| `VouchReport_<date>_<time>.json` | *Optional.* The results in a form other programs can read. |
| `VouchReport_<date>_<time>.zip` | *Optional.* All of the above in one zip file, ready to attach. |

While Vouch is capturing the full screen, it takes over the screen. Do not use the mouse
or keyboard until it finishes — usually a minute or two.

## 2. What you need

- A **Windows 10 or Windows 11** computer, signed in with your normal account.
- **Microsoft Edge** — already on every Windows computer.
- **PowerShell 7** — a free Microsoft program; step 3 shows how to install it.
- The **addresses (URLs) of the pages** you need as evidence, and a login for each
  application.

> **On a company computer?** Your IT department may need to install PowerShell 7 for you,
> or allow scripts to run. Show them this guide — everything Vouch needs is listed in
> this section, and it installs nothing else. Vouch controls Edge through Edge's
> "remote debugging" connection; if your organisation has switched that off (the Edge
> policy `RemoteDebuggingAllowed`), Vouch cannot work until IT allows it.

## 3. Install PowerShell 7 (once)

Windows already includes an old program called **Windows PowerShell**. Vouch needs the
newer **PowerShell 7**. They can live side by side.

**Easiest way — Microsoft Store:**

1. Click **Start**, type **Microsoft Store**, and open it.
2. Search for **PowerShell**.
3. Choose the one published by **Microsoft Corporation** and click **Get** (or
   **Install**).

**Alternative — one command:** click **Start**, type **Terminal**, open it, paste the
line below, and press **Enter**:

```powershell
winget install Microsoft.PowerShell
```

**Check it worked:** click **Start** and type **PowerShell 7**. You should see
*PowerShell 7* (or just *PowerShell*, with a black-and-blue icon) in the results. You do
not need to open it.

## 4. Get Vouch (once)

1. In Edge, go to **<https://github.com/pwsh/vouch>**.
2. Click the green **Code** button, then **Download ZIP**. A file called
   `vouch-main.zip` goes to your **Downloads** folder.
3. **Before you open it**, unblock it — this stops Windows from refusing to run the
   files later:
   1. Open your **Downloads** folder.
   2. Right-click `vouch-main.zip` and choose **Properties**.
   3. At the bottom of the **General** tab, tick **Unblock**, then click **OK**.
      (If there is no Unblock box, that is fine — nothing to do.)
4. Right-click `vouch-main.zip` again and choose **Extract All…** → **Extract**.
5. Move the extracted `vouch-main` folder to your **Documents** folder and rename it to
   **Vouch**.

You now have a folder `Documents\Vouch` that contains, among other things,
`Vouch-Designer.cmd`, `vouch.ps1`, the `designer` folder and `README.md`. Keep these
together: the Designer needs the `designer` folder next to `vouch.ps1`.

> **Tip — seeing file extensions.** Windows hides the end of file names (`.cmd`,
> `.json`) by default, which makes the files in this guide harder to recognise. In File
> Explorer, click **View** → **Show** → **File name extensions** to see them.

## 5. Start the Designer

Open `Documents\Vouch` in File Explorer and **double-click `Vouch-Designer.cmd`**.

**If Windows stops you:**

- *"Windows protected your PC"* (a blue box): the file came from the internet and was not
  unblocked. Click **More info**, then **Run anyway** — or close it, unblock the zip as in
  [step 4](#4-get-vouch-once), and extract it again.
- A black window saying *"Vouch Designer needs PowerShell 7, and it is not installed on
  this computer"*: do [step 3](#3-install-powershell-7-once), then double-click again.
- Nothing happens, or a window flashes and closes: see
  [The Designer does not start](#the-designer-does-not-start).

**Three windows open:**

1. A **black console window**. It says *Vouch Designer 2.0.0 is running…* and *Close the
   Designer window, or press Ctrl+C here, to stop the Designer.* Leave it open in the
   background (you can minimise it). It is the Designer's engine.
2. The **audit browser** — an Edge window that Vouch controls, on the left. This is
   where your sites open and where you sign in.
3. The **Designer window**, a narrow window on the right, titled *Vouch Designer*.

```text
+---------------------------------------------+------------------+
|  audit browser (Edge)                       |  Vouch Designer  |
|                                             |  New  Open… Save |
|  the site you are working on                |  Pages Output    |
|                                             |  Report Run      |
|                                             | ---------------- |
|                                             | Browser connected|
|                                             |  (page title)    |
|                                             |                  |
|                                             |  your pages and  |
|                                             |  their settings  |
+---------------------------------------------+------------------+
```

If the windows are not side by side, click **Tidy windows** in the Designer.

**At the top of the Designer window:**

- the name of the configuration you are working on (*New configuration* at first) and,
  when you have changes that are not saved yet, **Not saved**;
- the buttons **New**, **Open…**, **Save**, **Save as…**, **Import CSV…**, **Undo**,
  **Redo** and **Close**;
- four tabs: **Pages**, **Output**, **Report** and **Run**;
- the **browser line**: **Browser connected** with the title and address of the page
  shown in the audit browser — or **Browser not connected** with the reason, what
  to do, and a **Retry** button. You can edit and save without a browser; pointing at
  things, testing and running need it.

**To stop the Designer**, click **Close** in the Designer window (or close that window).
It asks about unsaved changes first. The audit browser closes with it if the
Designer opened it.

## 6. Sign in to your sites (once)

Vouch uses its **own Edge profile** — its own saved logins, separate from the Edge you
use every day (it lives in `%LOCALAPPDATA%\Vouch\EdgeProfile`). Edge only allows a
program to control a browser through a separate profile like this, and it keeps your
everyday browsing apart from the evidence.

1. In the **audit browser**, go to each application you want evidence from and
   **sign in**. Complete any multi-factor prompts, and tick **Stay signed in** /
   **Remember me** wherever it is offered.
2. That is all: the logins are kept in the Vouch profile for later runs, including
   scheduled ones.

Logins do expire eventually (how soon depends on each application). When a report says
*"Redirected to a sign-in page — the session has probably expired"* or *"possible login
required"*, sign in again in the audit browser.

> **A "Sign in to sync" bubble?** On a work computer, a new Vouch profile may show an
> Edge sign-in or sync bubble. Close it in the audit browser before a run: Vouch
> does not hide it, and in a full-screen capture it would be in the picture.

## 7. Add your first page

A **page** is one web address to capture, with the clicks and waits needed before the
screenshot. Pages are captured from top to bottom.

1. In the **audit browser**, open the page you need as evidence.
2. In the Designer, on the **Pages** tab, click **Add page from current tab**. The page
   appears in the list with the page's title as its name, and its settings open below.

Or click **Add blank page** and fill in the fields yourself.

**The page's fields:**

| Field | What to put there |
| --- | --- |
| **Name** | A short label for this evidence; it is the heading in the report. |
| **Address (URL)** | The page's address, starting with `https://` or `http://`. **Go** opens it in the audit browser. |
| **Notes** | Shown with the screenshots in the report — the control number, what to look at. |
| **Account for this page** | Only when this page is captured with another sign-in than the default account (set on the Report tab). |
| **Page id** | A short code such as `p001`, used to run one page on its own. Leave it as it is. |
| **Capture this page in full runs** | Switch off to keep a page in the file without capturing it. |

To change the order, drag a page in the list, or use **Move up** / **Move down**.
**Duplicate** copies a page; **Delete** removes it (**Undo** brings it back).

## 8. Tell Vouch what to capture

Under **What happens on this page** is the list of steps Vouch does after opening the
address, in order. Each **Capture** takes the screenshots. A page with no Capture gets
one at the end automatically: a screenshot of what is visible.

**Add a step** with the buttons under the list:

| Button | What it adds |
| --- | --- |
| **Pick something to click** | You click the thing in the audit browser; Vouch records how to click it again. |
| **Pick a scroll area** | You click inside the part of the page that should be scrolled; Vouch adds a Capture that scrolls it. |
| **Add click** | A click you describe yourself, by its words or a selector. |
| **Add capture** | A screenshot (see the choices below). |
| **Add wait** | Waits a number of seconds, for pages that fill in slowly. |
| **Add wait-for** | Waits until a particular element appears on the page. |
| **Add pause** | Stops and asks you to do something first (see below). |

Each step has **Edit**, **Test**, **↑**, **↓** and **Delete**. **Test** runs just that
step in the audit browser now, and shows the result under it. On a click step
the button says **Test (really clicks)** — it is a real click, and the site acts on it.

### Pointing at things: the Pick buttons

When you click a Pick button, the Designer shows *Waiting for you to click in the
browser…*. Click the thing in the audit browser. While you pick, the page's own
buttons and links do not react to your click; press **Esc** in the browser (or **Cancel
picking** in the Designer) to stop.

Vouch then shows **Record this?**: the thing you picked, and one or more ways to record
it, best first. Each way has a label — **Most robust**, **Robust**, **Less robust** or
**Fragile** — and the exact words or selector it would use. Vouch has already checked in
the page that each way finds exactly what you clicked. Pick one (the first is usually
right) and click **Use this**. You can change the words or the selector in the box below
the list; a changed value is not checked, so use **Test** afterwards.

### Common jobs

**Click a tab, then capture.** Click **Pick something to click** and click the tab in
the browser. In **Record this?** keep the first choice — usually the tab by its words,
such as *The “Audit Log” tab* — and click **Use this**. Then **Add capture**. Clicking by
the words keeps working when the site's design changes, and capital letters do not
matter. Vouch never clicks *Log out* / *Sign out* unless you write those words.

**Capture a long page, or one part of it.** In a Capture step, **What to capture** has
four choices:

| Choice | What it does |
| --- | --- |
| **What is visible** | One screenshot of what fits in the window. |
| **Auto-detect what scrolls** | Vouch finds what scrolls — the page, or the largest panel inside it — and captures all of it. |
| **The whole page** | Scrolls the page itself from top to bottom. |
| **A chosen area** | Scrolls one part of the page that you name (for example a table with its own scroll bar). **Pick a scroll area** fills this in for you. |

**How to save it**: **One screenshot per screenful** (works everywhere) or **One tall
image** (only with the capture area *Page content only*, when the page itself scrolls and
is not too long; otherwise Vouch takes screenfuls and says so in the report). A **Label**
is shown under the screenshots, useful when a page has several captures.

**Wait for something to appear.** **Add wait-for**, then **Pick** next to the field and
click the element that shows the page is ready (a table, a heading). Vouch waits until
it is on the page and visible. If it does not appear in time, the page gets a warning.
**Add wait** waits a fixed number of seconds instead.

**Pause for you** — for a multi-factor prompt, a cookie banner, or choosing a view.
**Add pause** and write the **Message to show**. During a run you started, Vouch stops at
that point and shows the **Vouch dialog**, a small window with your message (see
[step 19](#19-when-a-page-needs-more-time-or-your-input)). Do what is needed in the
audit browser, then click **Continue**. Scheduled runs never stop: they skip the
pause and the report notes it.

### Capture options for this page

**Capture options for this page** (under the page's fields) lets one page differ from
the run defaults set on the Output tab: capture area, zoom, an element to wait for, what
to do when the page is not ready, and time limits. Each says **Run default** until you
change it; **Reset to default** undoes a change. Change one only when this page needs
something else.

## 9. Test one page

Click **Test this page** (at the bottom of the page, or on the **Run** tab). Vouch
captures that one page exactly as a run would, and the **Run** tab shows:

- the result: for example *Test finished: this page was captured without problems.*,
  or the warnings, or what went wrong, with **What to do:**;
- a **preview** of the screenshots — click one to see it larger — and **Open the preview
  report**.

> **This is a test, not evidence.** The preview is temporary: it is replaced by the next
> test of the same page and removed when the Designer closes. Use **Run all pages** to
> make the report.

In the Pages list, each page then shows its last result, for example *Test OK 15:54* or
*Test: warning 15:54*.

A page test always uses your normal desktop, even when the virtual-desktop option is on.

## 10. Fill in the report details

The **Report** tab sets what the report says about itself. Everything is optional.

| Field | What it does |
| --- | --- |
| **Title** | The report's main heading (default *Audit Evidence Report*). |
| **Classification** | *None*, *Public*, *Internal*, *Private* or *Confidential*: a coloured banner at the top and bottom of the report, repeated on every printed page. |
| **Logo (optional)** | A PNG, JPEG, GIF or SVG file of at most 1 MB, copied into the report. **Browse…** shows a preview. |
| **Company name**, **Company details** | Shown at the top. Line breaks in the details are kept. |
| **Description** | What this evidence is for. |
| **Origin** | Where the capture was made — the office, the system, or the request it answers. |
| **Default account** | The account used to sign in to the applications. Shown in the report and stored inside each image. A page can name another one. |
| **Generated by** | Who produced the report. Empty: your Windows user name. |
| **Period covered** (**From**, **To**, **Name of the period**) | The period under audit, shown exactly as typed. The time of the captures is recorded separately. |
| **Show a contents list near the top** | A list of all pages with their result, linking to each one. On by default. |
| **Name of this configuration** | Only for you, to tell configurations apart. |

## 11. Choose where and how the evidence is saved

The **Output** tab holds the settings for the whole run.

**Where the report goes**

- **Output folder** — where reports are saved. A relative folder such as `reports` is
  inside the folder of your configuration file.
- **Report name** — leave empty for `VouchReport_<date>_<time>`. You can use `{date}`,
  `{time}`, `{title}`, `{period}`, `{classification}` and `{report}` (the default name).
  It is a file name, not a folder: characters Windows does not allow become `_`. A report
  with the same name in the folder is replaced.
- **Open the report when the run is finished** — only when a person started the run.

**Images**

- **Image format** — **JPEG** (smaller, the usual choice) or **PNG** (lossless, larger).
- **Images in the report**:
  - **Inside the report (one self-contained file)** — one file you can email or attach as
    it is. It can be large.
  - **Linked picture files** — the report stays small and shows the picture files saved
    next to it in `images\<report name>\`. **That folder must always travel with the
    report** (or use the zip): without it the pictures are missing and the report cannot
    be checked.
- **Also save every screenshot as a picture file** — the pictures in `images\<report
  name>\` too, with a `SHA256SUMS` list of their fingerprints.

**What each screenshot shows** — the **Capture area**:

| Choice | What is in the picture | What it shows the auditor |
| --- | --- | --- |
| **Full screen with the taskbar clock** (default) | The whole screen, with the Windows taskbar, clock and date. | The page as it was on screen, at the time on the clock. What auditors usually expect. |
| **Edge window only** | The Edge window with its title bar, tabs and address bar; no taskbar. | The real browser window and the address it showed, but not the clock. |
| **Page content only** | Only the web page, taken by the browser itself. Edge need not be in front. | The page content. There is no address bar or clock in the picture; the capture time and address are in the report and stored inside each image file. |

- **Zoom** — shows the pages zoomed, like Ctrl+plus or Ctrl+minus, without changing
  anything in Edge (25 to 500%, default 100%).
- **Capture on a separate, empty virtual desktop** — Vouch opens an empty Windows desktop
  for the run and closes it again at the end, so other programs do not appear in the
  taskbar of the screenshots. Your windows are untouched. Pinned taskbar icons still show.

**Logs and results**

- **Write a capture log** — the plain-text account of the run described in
  [step 1](#1-what-vouch-does-and-what-you-get). On by default; it also goes into the zip.
- **Write a JSON summary** — the results as a `.json` file for monitoring tools.
- **Count warnings as failure** — a run with warnings then counts as not passed (exit
  code 3), so a scheduled task shows it as failed. Without it, warnings count as success.
- **Console transcript folder (optional)** — a raw copy of everything the Vouch console
  shows, for troubleshooting scheduled runs. This is not the capture log.

**Zip** — **Put everything into one zip when done**: the report, its JSON summary, the
capture log and the picture files in one zip in the output folder. Extracting it gives a
working report. **Zip name** can use the same `{…}` words as the report name; an existing
zip is never replaced — a number is added.

**Browser** — **Keep the browser open after the run**.

**Advanced** (click to open): page load time limit, waits after loading and scrolling,
the most screenshots per scrolled page (default 30), an element to wait for on every
page, what to do when a page is not ready (**Capture anyway, with a warning** or **Ask me
(Continue / Wait / Skip)**), the time to answer a question, the browser connection port
and the Edge profile folder.

## 12. Save your configuration

Click **Save** (Ctrl+S). The first time, Windows asks where to save: choose a folder
such as `Documents\Vouch` and a name such as `q3-itgc.json`. The **configuration file**
holds all your pages and settings. Next time, open it with **Open…** — or drop the file
onto `Vouch-Designer.cmd` to start the Designer with it.

- **Not saved** at the top means you have changes that are not in the file yet.
- Each save keeps the previous version next to it as `<name>.json.bak`, in case you saved
  the wrong thing.
- Before saving, the Designer checks the configuration. Problems (for example an address
  without `https://`) are listed with a link to the field; the file is saved only when
  they are fixed.
- Relative folders in the file (such as `reports`) are read from the file's own folder.

## 13. Run everything

1. Close or minimise anything private on your screen — with the full-screen capture area
   the taskbar at the bottom is in the pictures, and so is the Designer's button on it.
2. Open the **Run** tab. Before a run it shows where the reports will go
   (*Reports of a full run go to: …*) and whether you are running edits that are not
   saved yet. A run uses what you see in the Designer, saved or not; the saved file is
   not changed by it.
3. Click **Run all pages**. Pages whose *Capture this page in full runs* is off are left
   out.
4. **Let go of the mouse and keyboard.** With the full-screen or Edge-window capture
   area, the audit browser is maximised over everything and moves through your
   pages by itself.
5. The Run tab shows the progress, for example *Running… · Full run · time 0:42 · 2 of 6
   pages done*, and each page with **OK**, **Warning** or **Failed** as it finishes. If a
   page asks for you, it says *Waiting for you in the Vouch window over the browser* —
   answer in that window ([step 19](#19-when-a-page-needs-more-time-or-your-input)).
6. When it is finished you see the result, for example *Finished: 6 page(s) captured, 1
   with warnings*, and the buttons **Open report**, **Open folder**, **Open capture log**
   and, with a zip, **Open zip location**. The Pages list shows each page's result, for
   example *Run OK 15:52*.

**Stop** ends the run after the current step; the report is still written for what was
captured. If the run has not stopped after a while, **Force stop** appears: it ends the
run at once, and its report may be missing.

You can keep editing during a run; the run is not affected by your edits.

> **Do not lock the computer or let the screen saver start during a run.** A locked
> screen produces black pictures.

## 14. Read the report and the capture log

Click **Open report**. **What's in it, from top to bottom:**

| Part | What it tells you |
| --- | --- |
| **Classification banner** | If you chose one. |
| **Company and title** | Logo, company name and details, the title. |
| **Run details** | Classification, description, origin, the period covered, the capture window (first to last screenshot), the account used, who generated the report, the capture log's name; then when the run started and finished, the time zone, the computer, the Windows user who captured, the browser version and whether the run opened Edge itself, the desktop used, the definition file, the image format, the screen resolution, the run ID and the manifest hash. Rows you left empty are not shown. |
| **Contents** | Every page with its result and number of images, linking to it. |
| **Summary** | Every page with its result. |
| **Integrity** | The run's ID, the **manifest hash**, and every screenshot's fingerprint (SHA-256). See [step 16](#16-check-a-report-later). |
| **Evidence** | One section per page: the address asked for and the one actually reached, the HTTP status, the capture area, the account, your notes, the steps that were done, and the screenshots with the exact time each was taken. |

**What the coloured labels mean:**

| Label | Meaning | What to do |
| --- | --- | --- |
| **OK** (green) | The page opened, every step worked, screenshots taken. | Nothing. |
| **WARNING** (amber) | Screenshots were taken, but something needs a look. The reason is written next to it. | Read the reason. *"Redirected to a sign-in page"* or *"possible login required"* means your login expired — sign in again ([step 6](#6-sign-in-to-your-sites-once)) and run again. A failed step means a button was not found — test that step in the Designer. |
| **FAILED** (red) | The page could not be opened at all, or the server returned an error such as *404 Not Found* (the error page is still photographed). | Check the address. Open it in the audit browser to see what happens. |

**The capture log** (**Open capture log**, or the `.log` file next to the report) is the
same run told in plain lines, each with its time, for example:

```text
2026-11-25 09:01:35.456 -06:00  Page 2 of 3: p002 "Settings tabs" - https://app.example.com/settings
2026-11-25 09:01:35.682 -06:00    Opened: https://app.example.com/settings (HTTP 200)
2026-11-25 09:01:35.900 -06:00    Action 1 clicktext:General: ok
2026-11-25 09:01:35.954 -06:00    Image 002_Settings_tabs_seg01.jpg: capture 1 "General", segment 1 of 1, page content only, zoom 100%, 1256x708 px, SHA-256 5351466f...
```

It is written while the run happens, so it also shows how far a run got that stopped
early. It is not part of the report's fingerprint check.

**The individual pictures** (when saved) are in `images\<report name>\`. Right-click one
→ **Properties** → **Details** to see what it shows: the page name and address
(*Title*), who took it (*Authors*), when (*Date taken*), and the full capture record
(*Comments*).

## 15. Share the evidence

- **Self-contained report** (the default): the `.html` file has all screenshots inside.
  Attach it as it is — the receiver needs nothing but a browser.
- **Linked picture files**: send the report **together with** its `images\<report name>\`
  folder — or simply the zip.
- **The zip** (turn on *Put everything into one zip when done*): the report, the capture
  log, the JSON summary and the pictures in one file. Extracting it anywhere gives a
  working report.
- **PDF**: with the report open in Edge, press **Ctrl+P**, choose **Save as PDF** as the
  printer, and click **Save**. Each page's evidence starts on a new PDF page, and the
  classification is printed on every page.

**Write down the manifest hash.** Copy the *Manifest SHA-256* line from the top of the
report into your workpaper, ticket or the email you send the report with. That is your
independent record of what the evidence looked like — see the next step.

## 16. Check a report later

Every screenshot gets a **fingerprint** (a SHA-256 hash): a long code like
`929c1dc0a552…0406` calculated from the picture itself. Change a single dot in the
picture and the fingerprint is completely different. The report lists every fingerprint,
plus one **manifest hash** that covers all of them together.

**To check a report**, open a PowerShell window in the Vouch folder
([step 17](#17-run-without-the-designer) shows how) and type:

```powershell
.\vouch.ps1 -Verify .\reports\VouchReport_2026-09-24_091502.html
```

(Type `.\vouch.ps1 -Verify .\reports\` and press **Tab** to fill in the file name.)
Every line should say **OK**, ending with **VERIFIED: … check(s) passed**. If anything
does not match, the lines concerned say **FAIL** and the result is **NOT VERIFIED**.
The check works on any Windows computer with PowerShell 7 and a copy of the Vouch
folder — Edge and logins are not needed. For a report with linked picture files, keep
its `images` folder next to it.

**What a successful check proves:**

- the report contains only what Vouch itself writes, in the way Vouch writes it;
- every picture the report shows is a screenshot whose fingerprint matches the one
  printed for it, shown under the page it belongs to — or the one small company logo;
- the capture time and address stored inside each picture match the report;
- no screenshot was removed, added, duplicated or put in another order (the manifest hash
  covers them all);
- with the picture files present, every file listed in `SHA256SUMS` is unchanged.

**What it does not prove:**

- that the **text** is unchanged. Words in the report — statuses such as OK or FAILED,
  addresses, notes, names, the run details, even the printed fingerprints — can be
  edited without the check noticing, as long as the edit keeps Vouch's layout. The
  **classification** can also be changed to another level by a careful edit. A page that
  has no screenshot can be removed altogether.
- that the report is the original. Someone who rebuilds a whole report with new
  pictures and new fingerprints gets a report that passes. **Only the manifest hash you
  wrote down at the time shows that a report is the original.** If it matches the one in
  the report and the check passes, the pictures are exactly those taken.
- anything about the **logo**: it is not checked (it can only appear small, at the top).
- anything about the capture log, the JSON summary or the zip.

**A report edited by hand usually stops verifying, even if the edit was honest** — for
example a paragraph added, or the file saved again by a program that changes its layout
or its text encoding. Keep the report as Vouch made it, and put your comments in the
workpaper instead.

## 17. Run without the Designer

Everything you set up in the Designer is in the configuration file, so it can also run
from a command — in a PowerShell window, a desktop shortcut, or a scheduled task.

**Open a PowerShell window in the Vouch folder:** in File Explorer, open
`Documents\Vouch`, right-click an empty area and choose **Open in Terminal** (Windows 10:
hold **Shift**, right-click, **Open PowerShell window here**). Type `pwsh` and press
**Enter**: that switches the window to PowerShell 7 (if it already is, nothing changes).
Every command below is typed there, followed by **Enter**.

The **Run** tab's **Command line** box has the commands for your saved file, each with a
**Copy** button (and a version for cmd.exe or a shortcut):

| Command | What it is for |
| --- | --- |
| **Run it** | Runs the saved file; every setting and page comes from the file. Paste it into the PowerShell window and press **Enter**. |
| **Run it with every setting spelled out** | The same run, with each setting that differs from Vouch's default written out (for example `-JpegQuality 70`). Change one to override the file for that one run: **a setting typed on the command line beats the file**, including the page's own capture options. |
| **Schedule it** | Sets up a Windows scheduled task that runs the saved file — see the next step. |

The commands run the file **as saved**: if *Not saved* shows, save first.

To run only some pages, add `-Only` and their page ids, for example
`-Only p002`. A page you switched off still runs when you name it. Pages are numbered in
the report and in the picture names over the pages actually run, so with `-Only p002`
that page is number 1.

## 18. Run it on a schedule (optional)

Vouch can run by itself. It uses the Windows **Task Scheduler**, but you do not need to
open it — one command sets everything up.

> **The one rule:** at the scheduled time, you must be **signed in to Windows with the
> screen unlocked**. Screenshots cannot be taken of a locked screen. That is why the
> most reliable choice for most people is **"a few minutes after I sign in"**.

**Set it up:** save your configuration, copy the **Schedule it** command from the Run
tab, paste it into a PowerShell window and press **Enter**. It looks like this:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "C:\Users\you\Documents\Vouch\Install-VouchSchedule.ps1" -ConfigPath "C:\Users\you\Documents\Vouch\q3-itgc.json" -Schedule AtLogOn
```

That runs the file 3 minutes after you sign in to Windows. For a set time instead,
replace `-Schedule AtLogOn` with `-At 07:30` (every weekday at 7:30), or with
`-Schedule Daily -At 07:30`, or `-Schedule Weekly -DaysOfWeek Monday -At 06:00`.

The command first checks the configuration file. If it has problems, they are listed
and **nothing is scheduled**. Otherwise you see *Scheduled task 'Vouch evidence capture'
installed*, where the reports and logs will go, and — under **Please note** — settings
that do not make sense when nobody is at the computer, with what the scheduled run does
instead. Running the command again replaces the schedule. The Designer only shows the
command; it never sets up a task by itself.

**What a scheduled run does differently:** it never asks anything and never waits for
you. A **pause** is skipped; a page that is not ready or asks for a sign-in is captured
as it is, with a warning; the report is not opened. It also keeps a console transcript
in a `logs` folder inside the output folder (unless your configuration names its own
transcript folder).

In the same PowerShell window, from the Vouch folder:

```powershell
.\Install-VouchSchedule.ps1 -RunNow      # try it straight away; leave the computer alone until Edge closes
.\Install-VouchSchedule.ps1 -Status      # next and last run, the result in plain words, the file it runs, where reports go
.\Install-VouchSchedule.ps1 -Uninstall   # turn it off (reports, logs and logins are kept)
```

If you change the configuration later, just save it: the task runs the file as it is at
that time. (The output folder of a task is read from the file too, unless you typed
`-OutputDir` when setting it up.)

**Warnings in scheduled runs:** a scheduled task reports a run with warnings as a
success unless **Count warnings as failure** is on in the Output tab. Turn it on if you
want an expired login to show up as a failed task (*Last Run Result 0x3*).

**Keeping the screen from locking at the scheduled time** (if you use a set time rather
than *AtLogOn*): open **Settings** → **System** → **Power** (Windows 11: **Power &
battery** → **Screen and sleep**) and set the screen and sleep times to cover the
scheduled time; if your organisation locks screens automatically, use *AtLogOn*.

## 19. When a page needs more time or your input

In a run **you** started (from the Designer or a PowerShell window), Vouch can stop and
ask you in the **Vouch dialog**, a small window that appears at the bottom right, above
the audit browser. It does so:

- at a **pause** step (window title *Vouch - Vouch is paused*), with your message;
- when a page is **not ready** in time (*Vouch - The page is not ready*) — only if *When
  a page is not ready* is set to **Ask me (Continue / Wait / Skip)**;
- when a page sent you to a **sign-in page** (*Vouch - Sign-in needed*) — with the same
  setting.

The window shows the page's name, the message, and three buttons:

- **Continue** — carry on. After a sign-in, Vouch opens the page once more and captures
  it.
- **Wait 30 s more** — waits longer (change the number next to it, 5 to 3600 seconds),
  then checks again or asks again.
- **Skip this page** — leaves the rest of this page out; the report says so.

A countdown shows what happens if nobody answers: after 5 minutes (the *Time to answer a
question* setting) Vouch continues by itself, and the report notes that nobody answered.
Closing the dialog counts as Continue. While it is open, the Designer's Run tab
says *Waiting for you in the Vouch window over the browser*.

**When nobody is there** (a scheduled run, or a command with `-NoPrompt`), Vouch never
asks: a pause is skipped and the page gets a warning saying so; a page that is not ready
or asks for a sign-in is captured as it is, with a warning.

## 20. Things Vouch cannot do

**Picking by pointing has limits.** Some things cannot be picked:

- something **inside a part of the page that comes from another website** (a *frame*
  from another site — common for embedded reports, chat windows and payment forms);
- something inside a **sealed page component** (built with what web developers call
  *shadow DOM*), or inside a frame that is shown scaled, mirrored or turned;
- something inside an element shown **full screen**;
- **menu items that only appear while the mouse pointer is over a menu** — a run could
  not reach them either;
- a page that **changes what is under the pointer at every click**.

Vouch tells you when it cannot record something. **What to do instead:** add the step
with **Add click** and type the words on the button, or a selector (see
[Finding a selector](#finding-a-selector)); for a page inside a frame from another site,
use that frame's own address as the page's address. A run can click such things only if
a selector reaches them; for menus that open on hover, look for another way to the page,
often its own address.

**While you pick:**

- The page's own buttons, links and fields do not act on your clicks or keys. But **a
  page that watches every click or key anywhere** ("click anywhere to close", its own
  keyboard shortcuts) may still react.
- **Keys:** Esc cancels; the arrow keys, Page Up/Down, Home/End and Space scroll; other
  keys do not reach the page's buttons, links and fields. The browser's own shortcuts
  (F5, Ctrl+F, zoom) still work — F5 really reloads the page. To work with the keyboard
  instead, cancel and type the words or the selector in the Designer.
- A page's **Alt + letter** shortcuts cannot be switched off; Vouch refuses such a pick
  and says so.
- **Typing that does not come from plain keys** — an input method for Chinese, Japanese
  or Korean, the emoji panel (Win + .), clipboard history (Win + V), voice typing — is
  held back where possible; if a field in the page starts to change anyway, picking
  stops and says so. Check that field afterwards.
- Starting a pick takes the keyboard focus away from the page; click where you want to
  continue afterwards.
- Most menus stay open while you point. A menu built as a sealed page component closes
  when you click.
- If the page reloads by itself during a pick, your clicks do nothing for a moment until
  Vouch's layer is back.

**Other limits:**

- Only the **primary display** is captured. Keep the audit browser on it.
- Vouch works with **Microsoft Edge** only.
- **One tall image** is limited to 16,384 pixels in height; a longer page is captured in
  screenfuls, and the report says so.

## 21. If you already use a CSV file

Capture lists made as CSV files for earlier versions of Vouch still work, unchanged:

```powershell
.\vouch.ps1 -CsvPath .\captures.csv
```

To move to the Designer, click **Import CSV…** and choose the file. Its rows become
pages (with *Add to this configuration* or *Start a new configuration* if the Designer
already has pages); then save as a configuration file. The CSV columns map like this:
`click:` and `clicktext:` become click steps, `wait:` a wait step, and
`ScrollFullPage` `Y` a final capture that scrolls (*Auto-detect what scrolls*).

A CSV run in this version also writes, compared with earlier versions:

- the **contents list** near the top of the report (switch off with `-NoIndex`);
- extra rows in the run details: *Capture window*, *Report generated by*, *Capture log*,
  and a *Capture area* line for each page;
- the **capture log** file next to the report (switch off with `-NoCaptureLog`).

The columns of a CSV file are **Name**, **Url**, **Steps** (optional:
`clicktext:Words`, `wait:3`, `click:#selector`, separated by `;`), **ScrollFullPage**
(`Y`/`N`) and **Notes** (optional). `captures.template.csv` has an example row for each
common situation. The same examples, ready to paste into Notepad (keep the first line
only once, at the top of your file):

```
Name,Url,Steps,ScrollFullPage,Notes
Simple page - one screen,https://app.example.com/admin/security,,N,The page is right as it opens.
Long list - whole page,https://app.example.com/admin/users?role=admin,,Y,Whole page - for user lists and logs.
Click a tab by its words,https://app.example.com/settings,clicktext:Password Policy,N,Clicks the tab showing these words.
Two clicks in a row,https://app.example.com/settings,clicktext:Security; clicktext:Multi-factor authentication,N,Steps run left to right.
Slow page - wait first,https://reports.example.com/backup-status,wait:5,N,Waits 5 seconds before the screenshot.
Click then wait then capture all,https://app.example.com/audit,clicktext:Audit Log; wait:3,Y,Tab then wait then whole page.
Click an exact element (selector),https://app.example.com/admin,click:#tab-roles,N,When the same words appear twice.
Notes with commas,https://app.example.com/admin/retention,,N,"Text with commas, like this, goes in double quotes."
Page reached through a menu,https://portal.example.com/,clicktext:Administration; clicktext:Change approvals; wait:2,Y,Click through a menu to the evidence.
```

If Excel saves your CSV with semicolons instead of commas (Windows set to use commas for
decimals), Vouch says the *Url column is missing*: open the file in Notepad, check the
columns are separated by commas, and save it there — or import it into the Designer and
work with the configuration file instead.

---

## When something goes wrong

### The Designer does not start

- **A window flashes and closes**, or nothing happens: open a PowerShell window in the
  Vouch folder ([step 17](#17-run-without-the-designer)) and type
  `.\Vouch-Designer.cmd`. The message stays on screen.
- **"The Vouch Designer needs the folder 'designer' next to vouch.ps1"**: copy the whole
  Vouch folder, not only `vouch.ps1`.
- **"… cannot be loaded … is not digitally signed"**: Windows is blocking the downloaded
  files. In a PowerShell window in the Vouch folder, type
  `Get-ChildItem -Recurse | Unblock-File` and try again. If it still happens, your
  organisation controls this setting — ask IT to allow the Vouch scripts to run.
- **The console says the Designer window could not be opened**: it prints an address
  starting with `http://localhost:`. Open that address in Edge on this computer.

### "Browser not connected"

The browser line says why, and what to do; then click **Retry**. The usual reasons:

- **Edge is already open with the audit profile, but without the connection Vouch
  needs** — usually an Edge window left from `.\vouch.ps1 -LoginSetup`, or one left open
  by an earlier Designer. Close every Edge window that uses the Vouch profile (look on
  the taskbar and on other desktops), then **Retry**.
- **Your organisation has switched off remote debugging in Edge** (the Edge policy
  `RemoteDebuggingAllowed`). Vouch cannot work until your IT department allows it on this
  computer. You can still edit and save configurations.
- **Another program is using port 9222.** Close that program and **Retry**, or choose
  another port: Output tab → *Advanced* → *Browser connection port*, save, then
  **Retry**.
- **The audit Edge window was closed** — click **Retry** to open it again.

### The Designer says it is not answering

*"The Vouch Designer is not answering"* means its engine (the black console window) has
stopped — it was closed, or the computer slept. Changes you did not save are lost. Close
the Designer window and start `Vouch-Designer.cmd` again; your saved file is safe.

If you close the **console window** with its **X**, the Designer stops at once, but its
window stays open, showing that message: close it too. An audit browser window that stays
open after that can be closed as well. (Click **Close** in the Designer next time; that
stops everything cleanly.)

### Problems in a run

**Black or blank screenshots.** The screen was locked, the screen saver started, or a
Remote Desktop session was minimised or disconnected during the run. Run again with the
screen visible and leave the computer alone.

**Every page says "Redirected to a sign-in page" or "possible login required".** Your
saved logins have expired. Sign in again in the audit browser
([step 6](#6-sign-in-to-your-sites-once)).

**A click step says "No clickable element with the text … was found".** The words on the
button are different, or the page had not finished loading. Use **Test** on that step;
add a **wait-for** before it.

**A step fails with "… The page also contains 1 frame(s) from another site, which Vouch
cannot look inside."** The button is inside a part of the page that comes from another
website. Use that part's own address as the page's address: in your normal Edge,
right-click inside that part → **Open frame in new tab** (if offered) shows it.

**WARNING: "Another scrolling area (…) was not scrolled" or "A frame from another site
(…) cannot be scrolled".** The page has more than one part that scrolls on its own, and
Vouch captured the largest one. Add a capture with **Pick a scroll area** for the other
part, or capture that part's own address as another page.

**Other windows or pop-ups appear in the screenshots.** Something came to the front
during the run. Turn on *Do not disturb* (click the clock → the bell icon) before a run,
and use the virtual-desktop option.

**A sign-in or sync bubble from Edge is in the full-screen screenshots** (work
computers): close it once in the audit browser before the run, or use the capture
area *Page content only*, which shows only the page.

**Pictures look cut off or scaled with display scaling above 100%.** The *Edge window
only* area has not yet been tried on every scaling setting. If its pictures look wrong,
use *Full screen with the taskbar clock* or *Page content only*, and tell whoever
supports Vouch for you.

**A page with a fixed header looks odd in "One tall image".** Headers that stay at the
top of the screen can appear once at the top of a tall image, or not where you expect.
Use *One screenshot per screenful* for such pages.

**The report's Desktop line says the separate desktop "could not be confirmed".** The
run still worked, on your normal desktop; other programs may show in the taskbar.

### Where to look

- **The capture log** (`<report>.log`, next to the report): what happened, step by step.
- **The Run tab**: when a run could not start or ended unexpectedly, it shows what the
  run said last and **What to do**.
- **Scheduled runs**: `.\Install-VouchSchedule.ps1 -Status` shows the last result and the
  newest report and console transcript (in `logs` inside the output folder).
- **Still stuck?** Run the command from the Run tab in a PowerShell window, add
  `-Verbose` at the end, and send the text shown — and the capture log — to whoever
  supports Vouch for you.

---

## Quick reference card

**Start:** double-click `Documents\Vouch\Vouch-Designer.cmd`.

| I want to… | In the Designer |
| --- | --- |
| Sign in to my sites | Sign in in the audit browser (once; again when logins expire) |
| Add a page | Open it in the audit browser → Pages → **Add page from current tab** |
| Click a tab before the screenshot | **Pick something to click** → click it in the browser → **Use this** |
| Capture a long page or a scrolling panel | **Add capture** → *Auto-detect what scrolls*, or **Pick a scroll area** |
| Wait for the page to fill in | **Add wait-for** → **Pick** |
| Stop for MFA or a cookie banner | **Add pause** |
| Try one page | **Test this page** |
| Set title, logo, classification, period | **Report** tab |
| Choose folder, image format, zip, capture area | **Output** tab |
| Save | **Save** (Ctrl+S) |
| Take the evidence | **Run** → **Run all pages** |
| Open the result | **Open report**, **Open capture log** |

Commands, typed in a PowerShell window in the Vouch folder:

| I want to… | Type |
| --- | --- |
| Run a saved configuration | `.\vouch.ps1 -ConfigPath .\q3-itgc.json` |
| Run only some pages | `.\vouch.ps1 -ConfigPath .\q3-itgc.json -Only p002,p005` |
| Check a report has not been changed | `.\vouch.ps1 -Verify .\reports\<report file>` |
| Run automatically after I sign in | `.\Install-VouchSchedule.ps1 -ConfigPath .\q3-itgc.json -Schedule AtLogOn` |
| Run automatically every weekday at 7:30 | `.\Install-VouchSchedule.ps1 -ConfigPath .\q3-itgc.json -At 07:30` |
| Start the scheduled run now | `.\Install-VouchSchedule.ps1 -RunNow` |
| See how the scheduled runs went | `.\Install-VouchSchedule.ps1 -Status` |
| Stop the scheduled runs | `.\Install-VouchSchedule.ps1 -Uninstall` |
| Run an old CSV capture list | `.\vouch.ps1 -CsvPath .\captures.csv` |

---

## Finding a selector

Only needed when picking does not work and the words on a button cannot tell two
buttons apart.

1. Open the page in the audit browser and press **F12**. A panel opens on the
   side.
2. Press **Ctrl+Shift+C**, then click the button or tab you want Vouch to click.
3. In the panel, the matching line is highlighted. Right-click it → **Copy** → **Copy
   selector**.
4. In the Designer, **Add click** → **Click by** *An exact element (selector)* → paste.
   Short selectors that start with `#` are the most reliable; if yours is very long
   (`body > div:nth-child(3) > …`), ask someone technical to shorten it. Use **Test** to
   check it.
5. Close the panel with **F12**.

---

## Words used in this guide

| Word | Meaning |
| --- | --- |
| **Designer** | The Vouch Designer window, where you set up pages and settings and start runs. |
| **Vouch dialog** | The small window that asks you during a run: Continue, Wait or Skip this page. |
| **Audit browser** | The Edge window Vouch controls, with its own logins (the *audit profile*). The Designer calls it the audit browser or audit Edge. |
| **Configuration file** | The `.json` file that holds your pages and settings. |
| **Page** | One web address to capture, with the steps before the screenshot. |
| **Step** | Something Vouch does on a page: click, wait, wait for, pause, capture. |
| **Capture area** | What each screenshot shows: the full screen, the Edge window, or the page content. |
| **Report** | The `.html` file Vouch produces, with the screenshots. Opens in any browser. |
| **Capture log** | The plain-text, time-stamped account of a run, next to the report. |
| **Hash / fingerprint (SHA-256)** | A 64-character code calculated from a file. The same file always gives the same code; any change gives a different one. |
| **Manifest hash** | One hash that covers all screenshots of a run together. |
| **Virtual desktop** | An extra, empty desktop Windows can show instead of your usual one. Vouch can use one so your other programs stay out of the pictures. |
| **Selector** | A precise description of one element on a web page, such as `#tab-users`. |
| **Frame** | A part of a web page that shows another page inside it, sometimes from another website. |
| **CSV** | A simple spreadsheet file (*comma-separated values*), the older way of listing pages. |
| **URL** | A web page address, as shown in the browser's address bar. |
| **PowerShell 7** | A free Microsoft program for running commands; Vouch is written for it. |
| **Session / login expired** | The application has forgotten that you signed in; sign in again in the audit browser. |
