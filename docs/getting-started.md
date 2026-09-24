# Getting started with Vouch — a step-by-step guide

This guide is for people who need audit evidence screenshots and are not programmers.
It walks you through everything once, in order, and tells you what you should see at each
step. Setting up takes about 20 minutes the first time; after that, taking a full set of
evidence is one command, or no command at all if you schedule it.

If something here does not match what you see, jump to
[When something goes wrong](#when-something-goes-wrong).

**Contents**

1. [What Vouch does](#1-what-vouch-does)
2. [What you need](#2-what-you-need)
3. [Install PowerShell 7](#3-install-powershell-7-once)
4. [Download Vouch](#4-download-vouch-once)
5. [Open the Vouch command window](#5-open-the-vouch-command-window)
6. [Sign in to your applications](#6-sign-in-to-your-applications-once)
7. [Make your capture list](#7-make-your-capture-list)
8. [Take the evidence](#8-take-the-evidence)
9. [Open, read and share the report](#9-open-read-and-share-the-report)
10. [Run it automatically on a schedule](#10-run-it-automatically-on-a-schedule-optional)
11. [Prove the evidence has not changed](#11-prove-the-evidence-has-not-changed)
12. [When something goes wrong](#when-something-goes-wrong)
13. [Quick reference card](#quick-reference-card)
14. [Words used in this guide](#words-used-in-this-guide)

---

## 1. What Vouch does

You give Vouch a list of web pages — for example the password-policy page of an
application, or its list of administrator accounts. Vouch then:

- opens each page in Microsoft Edge, one after another, by itself;
- clicks through to the right tab or section if you tell it to;
- takes a **real screenshot of your whole screen**, so the Windows clock and date at the
  bottom right are in every picture — that is what auditors want to see;
- scrolls down long pages and takes one screenshot per screenful;
- puts everything into **one report file** that you can open in any browser, print to
  PDF, or attach to a workpaper.

It also records exactly when and where each screenshot was taken, and gives every
screenshot a unique fingerprint (a "hash") so anyone can check later that nothing has
been edited.

While Vouch is working, it takes over the screen. You should not use the mouse or
keyboard until it finishes — usually a minute or two.

## 2. What you need

- A **Windows 10 or Windows 11** computer, signed in with your normal account.
- **Microsoft Edge** — already on every Windows computer.
- **PowerShell 7** — a free Microsoft program; step 3 shows how to install it.
- The **addresses (URLs) of the pages** you need as evidence, and a login for each
  application.

> **On a company computer?** Your IT department may need to install PowerShell 7 for you,
> or allow scripts to run. Show them this guide — everything Vouch needs is listed in
> this section, and it installs nothing else.

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
not need to open it yet.

## 4. Download Vouch (once)

1. In Edge, go to **https://github.com/pwsh/vouch**.
2. Click the green **Code** button, then **Download ZIP**. A file called
   `vouch-main.zip` goes to your **Downloads** folder.
3. **Before you open it**, unblock it — this stops Windows from refusing to run the
   scripts later:
   1. Open your **Downloads** folder.
   2. Right-click `vouch-main.zip` and choose **Properties**.
   3. At the bottom of the **General** tab, tick **Unblock**, then click **OK**.
      (If there is no Unblock box, that is fine — nothing to do.)
4. Right-click `vouch-main.zip` again and choose **Extract All…** → **Extract**.
5. Move the extracted `vouch-main` folder to your **Documents** folder and rename it to
   **Vouch**.

You now have a folder `Documents\Vouch` that contains, among other things, `vouch.ps1`,
`captures.sample.csv` and `README.md`. Everything Vouch produces will be saved inside
this folder.

> **Tip — seeing file extensions.** Windows hides the end of file names (`.ps1`,
> `.csv`) by default, which makes the files in this guide harder to recognise. In File
> Explorer, click **View** → **Show** → **File name extensions** to see them.

## 5. Open the Vouch command window

You type Vouch's commands into a PowerShell 7 window that is "standing in" the Vouch
folder. You will do this every time you use Vouch by hand.

1. Open **File Explorer** and go to **Documents** → **Vouch**.
2. Right-click an empty area inside the folder and choose **Open in Terminal**.
   (On Windows 10: hold **Shift**, right-click an empty area, and choose **Open
   PowerShell window here**.)
3. A window opens. Type the following and press **Enter**:

   ```powershell
   pwsh
   ```

4. You should see a line such as **PowerShell 7.6.6**. The line you type on now starts
   with `PS` followed by the folder, for example
   `PS C:\Users\you\Documents\Vouch>`.

That is the **Vouch command window**. Every command in this guide is typed there,
followed by **Enter**.

> **Typing tips.** You can paste into the window with **Ctrl+V** or a right-click. Press
> the **Up arrow** to bring back a command you used before. When typing a file name,
> type the first few letters and press **Tab** — the window completes the name for you.

**Only the first time:** if you did not tick *Unblock* in step 4, type this once to
unblock all the Vouch files:

```powershell
Get-ChildItem -Recurse | Unblock-File
```

## 6. Sign in to your applications (once)

Vouch uses its **own copy of Edge** with its own saved logins, separate from the Edge you
use every day. You sign in to your applications there once, and Vouch reuses those
logins every time.

1. In the Vouch command window, type:

   ```powershell
   .\vouch.ps1 -LoginSetup
   ```

2. An Edge window opens with an empty page. In it, go to each application you want
   evidence from and **sign in**. Complete any multi-factor prompts, and tick **Stay
   signed in** / **Remember me** wherever it is offered.
3. When you have signed in to everything, go back to the Vouch command window and press
   **Enter**. Vouch closes that Edge window and saves the logins. You should see
   **Sessions saved.**

Logins do expire eventually (how soon depends on each application). When a report says
*"Redirected to a sign-in page — the session has probably expired"*, simply repeat this
step.

## 7. Make your capture list

The capture list tells Vouch which pages to photograph. It is a spreadsheet saved as a
**CSV** file named `captures.csv` in the Vouch folder. **One row = one piece of
evidence.**

**Create it from the example.** In the Vouch command window, type:

```powershell
Copy-Item .\captures.sample.csv .\captures.csv
start .\captures.csv
```

The second line opens it in Excel (or whichever program opens CSV files on your
computer). Replace the example rows with your own — keep the first row (the column
names) exactly as it is.

### The columns

| Column | Fill in | Example |
| --- | --- | --- |
| **Name** | A short label for the evidence. Shown in the report. | `Payroll - Password policy` |
| **Url** | The page address, copied from Edge's address bar. Must start with `https://` or `http://`. | `https://payroll.example.com/admin/security` |
| **Steps** | *Optional.* What to click on the page before the screenshot — see below. Leave empty if the page is right as it opens. | `clicktext:Password Policy` |
| **ScrollFullPage** | `Y` to capture the whole page, however long (one screenshot per screenful) - also when the content scrolls inside a panel or a frame of the page. `N` or empty for just what fits on the screen. | `Y` |
| **Notes** | *Optional.* Anything the reviewer should know — the control number, what to look at. Copied into the report. | `ITGC-04: minimum length must be 12` |

**Getting the Url right:** open the page in your normal Edge, click the address bar,
press **Ctrl+C**, and paste it into the Url cell. If you need a page that only appears
after clicking a tab, use the address of the page the tab sits on and add a step.

### Steps: clicking before the screenshot

Most pages need no steps. When the evidence is behind a tab or a link, add one:

| Step | What it does | Example |
| --- | --- | --- |
| `clicktext:<the words on the button>` | Clicks the link, button or tab showing those words. Capital letters do not matter. | `clicktext:Audit Log` |
| `wait:<seconds>` | Waits, for pages that fill in slowly. | `wait:3` |
| `click:<selector>` | Clicks an exact element — for when the words appear more than once. See [Finding a selector](#finding-a-selector). | `click:#tab-users` |

Several steps are separated with a semicolon: `clicktext:Settings; clicktext:Audit Log; wait:2`

Use `clicktext:` whenever you can — it keeps working when the application's design
changes. Vouch never clicks a *Log out* / *Sign out* button unless you spell those
words out.

### Rows you can copy and paste

The file **`captures.template.csv`** in the Vouch folder has one example row for each
common situation, with its *Notes* explaining what it does. Open it
(`start .\captures.template.csv`), copy the rows that match your pages into your
`captures.csv`, and change the **Name**, **Url** and the words in **Steps**.

The same examples, ready to paste into Notepad (keep the first line only once, at the
top of your file):

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

Pasting into Excel instead? Paste into cell A1, then use **Data** → **Text to Columns**
→ **Delimited** → tick **Comma** → **Finish** to split the lines into columns.

### A good first list

For your first try, use one or two pages you know well. For example:

```
Name,Url,Steps,ScrollFullPage,Notes
Company website home page,https://www.example.com/,,N,Practice run
Payroll - Password policy,https://payroll.example.com/admin/security,clicktext:Password Policy,N,ITGC-04
```

### Saving from Excel

Choose **File** → **Save As**, and as the file type pick **CSV UTF-8 (Comma delimited)
(\*.csv)**. Keep the name `captures.csv`. If Excel asks about keeping the format, choose
**Keep Current Format** / **Yes**.

> **If your Windows uses commas for decimals** (for example German, French or Dutch
> settings), Excel may save the file with semicolons instead of commas, and Vouch will
> say the *Url column is missing*. Open `captures.csv` in **Notepad** instead
> (right-click → **Open with** → **Notepad**), check that the columns are separated by
> commas, and save it there.

## 8. Take the evidence

1. Close or minimise anything private on your screen — the taskbar at the bottom will be
   in the pictures.
2. In the Vouch command window, type:

   ```powershell
   .\vouch.ps1 -UseVirtualDesktop -SaveImages
   ```

   - `-UseVirtualDesktop` makes Vouch work on a separate, empty desktop, so other
     programs you have open do not appear in the taskbar in the screenshots. Your
     windows are untouched and you return to them at the end.
   - `-SaveImages` keeps every screenshot as a separate picture file as well, next to
     the report.
3. **Let go of the mouse and keyboard.** Edge opens full screen and moves through your
   pages by itself. Each page takes a few seconds; long pages captured in full take
   longer.
4. When it is finished, Edge closes and the window shows a summary, for example:

   ```
   Done. 12 item(s): 11 OK, 1 warning(s), 0 failed. 19 screenshot(s).
   Report: C:\Users\you\Documents\Vouch\reports\VouchReport_2026-09-24_091502.html (6.2 MB)
   ```

If Vouch stops straight away with *"The capture definition CSV has … problem(s)"*, it
lists exactly which row and column is wrong — fix those in `captures.csv` and run the
command again. Nothing was captured, so nothing is lost.

> **Do not lock the computer or let the screen saver start during a run.** A locked
> screen produces black pictures.

## 9. Open, read and share the report

**Open it:** in the Vouch command window, type

```powershell
start .\reports
```

This opens the `reports` folder. Double-click the newest `VouchReport_….html` file — it
opens in your browser. (Or copy the *Report:* path from the summary and paste it into
Edge's address bar.)

**What's in it, from top to bottom:**

| Part | What it tells you |
| --- | --- |
| **Header table** | When the run started and finished, the time zone, the computer, who ran it, and the browser version. |
| **Summary** | Every page with its result. Click a number to jump to that page's screenshots. |
| **Integrity** | The run's ID, the **manifest hash**, and every screenshot's fingerprint (SHA-256). See [step 11](#11-prove-the-evidence-has-not-changed). |
| **Evidence** | One section per page: the address asked for and the one actually reached, what was clicked, your notes, and the screenshots with the exact time each was taken. |

**What the coloured labels mean:**

| Label | Meaning | What to do |
| --- | --- | --- |
| **OK** (green) | The page opened, every step worked, screenshots taken. | Nothing. |
| **WARNING** (amber) | Screenshots were taken, but something needs a look. The reason is written next to it. | Read the reason. *"Redirected to a sign-in page"* means your login expired — redo [step 6](#6-sign-in-to-your-applications-once) and run again. *"Step failed"* means a button was not found — check the words in your Steps. |
| **FAILED** (red) | The page could not be opened at all, or the server returned an error such as *404 Not Found* (the error page is still photographed). | Check the address. Open it in your own Edge to see what happens. |

**Share it:** the report is a single file with all screenshots inside it. Attach it to
an email or a workpaper as it is — the receiver needs nothing but a browser.

**Turn it into a PDF:** with the report open in Edge, press **Ctrl+P**, choose **Save
as PDF** (or *Microsoft Print to PDF*) as the printer, and click **Save**. Each page's
evidence starts on a new PDF page.

**The individual pictures** (with `-SaveImages`) are in
`reports\images\<report name>\`. Right-click any of them → **Properties** →
**Details** to see what it shows: the page name and address (*Title*), who took it
(*Authors*), when (*Date taken*), and the full capture record (*Comments*).

## 10. Run it automatically on a schedule (optional)

Vouch can run by itself at a set time. It uses the Windows **Task Scheduler**, but you do
not need to open it — one command sets everything up.

> **The one rule:** at the scheduled time, you must be **signed in to Windows with the
> screen unlocked**. Screenshots cannot be taken of a locked screen. That is why the
> most reliable choice for most people is **"a few minutes after I sign in"**.

**Set it up** — in the Vouch command window, type **one** of these:

```powershell
# A few minutes after you sign in to Windows (recommended)
.\Install-VouchSchedule.ps1 -Schedule AtLogOn -UseVirtualDesktop

# Every weekday at 7:30 in the morning
.\Install-VouchSchedule.ps1 -At 07:30 -UseVirtualDesktop

# Every Monday at 6:00
.\Install-VouchSchedule.ps1 -Schedule Weekly -DaysOfWeek Monday -At 06:00 -UseVirtualDesktop
```

You should see *Scheduled task 'Vouch evidence capture' installed*, followed by where the
reports and logs will go. Running the command again with different times simply
replaces the schedule.

**Try it straight away:**

```powershell
.\Install-VouchSchedule.ps1 -RunNow
```

Then leave the computer alone until Edge closes.

**See how it went:**

```powershell
.\Install-VouchSchedule.ps1 -Status
```

This shows when it runs next, when it last ran, the result in plain words (for example
*"Warnings only — often an expired login"*), the counts from the last report, and where
the newest report and log file are.

**Turn it off:**

```powershell
.\Install-VouchSchedule.ps1 -Uninstall
```

Your reports, logs and saved logins are kept.

**Keeping the screen from locking at the scheduled time** (if you use a set time rather
than *AtLogOn*): open **Settings** → **System** → **Power** (Windows 11: **Power &
battery** → **Screen and sleep**) and set the screen and sleep times to cover the
scheduled time; if your organisation locks screens automatically, use *AtLogOn* instead.

## 11. Prove the evidence has not changed

Every screenshot gets a **fingerprint** (a SHA-256 hash): a long code like
`929c1dc0a552…0406` calculated from the picture itself. Change a single dot in the
picture and the fingerprint is completely different. The report lists every fingerprint,
plus one **manifest hash** that covers all of them together.

**When you take the evidence:** copy the *Manifest SHA-256* line from the top of the
report into your workpaper, ticket or the email you send the report with. That is your
independent record of what the evidence looked like.

**Later, anyone can check the report** — in the Vouch command window:

```powershell
.\vouch.ps1 -Verify .\reports\VouchReport_2026-09-24_091502.html
```

(Type `.\vouch.ps1 -Verify .\reports\` and press **Tab** to fill in the file name.)

Every line should say **OK**, ending with **VERIFIED: … check(s) passed**. Then compare
the manifest hash shown in the report with the one you recorded. If both are true, the
report and pictures are exactly as they were taken. If anything was changed, the lines
concerned say **FAIL** and the result is **NOT VERIFIED**.

The check works on any Windows computer with PowerShell 7 and a copy of the Vouch
folder — Edge and logins are not needed.

---

## When something goes wrong

**"… cannot be loaded … is not digitally signed. You cannot run this script on the
current system."**
Windows is blocking the downloaded files. In the Vouch command window, type
`Get-ChildItem -Recurse | Unblock-File` and try again. If it still happens, your
organisation controls this setting — ask IT to allow the Vouch scripts to run.

**"The term '.\vouch.ps1' is not recognized …"**
The command window is not standing in the Vouch folder. Close it and open it again as
in [step 5](#5-open-the-vouch-command-window).

**"The script 'vouch.ps1' cannot be run because it contained a "#requires" statement
for Windows PowerShell 7.0 …"**
You are in the old Windows PowerShell. Type `pwsh`, press **Enter**, and try again.

**"The term 'pwsh' is not recognized …"**
PowerShell 7 is not installed yet — see [step 3](#3-install-powershell-7-once).

**"Capture definition CSV not found"**
There is no `captures.csv` in the Vouch folder yet — see [step 7](#7-make-your-capture-list).
Check the name is exactly `captures.csv` (with file name extensions shown, it must not
be `captures.csv.csv`).

**"missing the required 'Url' column"**
The file was saved with semicolons, or the first row was changed. See *Saving from
Excel* in [step 7](#saving-from-excel).

**"Edge is already running with the audit profile … but without the DevTools port"**
An Edge window from `-LoginSetup` is still open. Close every Edge window that opened for
Vouch and try again.

**Every page says "Redirected to a sign-in page" or "possible login required".**
Your saved logins have expired. Repeat [step 6](#6-sign-in-to-your-applications-once).

**A step says "No clickable element with the text … was found".**
The words on the button are different from what is in *Steps*, or the page had not
finished loading. Check the exact words on the page, or add `wait:3;` before the step.

**A step fails with "… The page also contains 1 frame(s) from another site, which Vouch
cannot look inside."**
The button is inside a part of the page that comes from a different website (a
*frame*), and browsers do not let Vouch reach into those. Open that part's own address
instead: in your normal Edge, right-click inside that part of the page → **View frame
source** or **Open frame in new tab** (if offered) shows its address; use that as the
**Url** of the row.

**WARNING: "Another scrolling area (…) was not scrolled" or "A frame from another site
(…) cannot be scrolled".**
The page has more than one part that scrolls on its own, and Vouch captured the largest
one. Content hidden in the other part is not in the screenshots. If you need it, capture
that part's own address in a separate row (see the entry above), or use a `clicktext:`
step to open it full size first.

**The screenshots are black or blank.**
The screen was locked, the screen saver started, or a Remote Desktop session was
minimised or disconnected during the run. Run again with the screen visible and leave
the computer alone.

**Other windows or pop-ups appear in the screenshots.**
Something came to the front during the run — a notification, or someone used the
computer. Turn on *Do not disturb* (click the clock → the bell icon) before a run, and
use `-UseVirtualDesktop`.

**The report's Desktop line says the separate desktop "could not be confirmed".**
The run still worked, on your normal desktop; other programs may show in the taskbar.
Close them and run again.

**Still stuck?** In the Vouch command window, run the same command again with
`-Verbose` at the end, and send the text shown to whoever supports Vouch for you. For
scheduled runs, `.\Install-VouchSchedule.ps1 -Status` shows where the log file of the
last run is — send that file.

---

## Quick reference card

All commands are typed in the Vouch command window
(Documents\Vouch → right-click → **Open in Terminal** → type `pwsh`).

| I want to… | Type |
| --- | --- |
| Sign in to my applications (first time, or when logins expire) | `.\vouch.ps1 -LoginSetup` |
| Create my capture list from the example | `Copy-Item .\captures.sample.csv .\captures.csv` |
| See example rows to copy | `start .\captures.template.csv` |
| Open my capture list | `start .\captures.csv` |
| Take the evidence now | `.\vouch.ps1 -UseVirtualDesktop -SaveImages` |
| Take evidence from a different list, into a different folder | `.\vouch.ps1 -CsvPath .\q3-list.csv -OutputDir .\Q3 -UseVirtualDesktop` |
| Open the reports folder | `start .\reports` |
| Check a report has not been changed | `.\vouch.ps1 -Verify .\reports\<report file>` |
| Run automatically after I sign in | `.\Install-VouchSchedule.ps1 -Schedule AtLogOn -UseVirtualDesktop` |
| Run automatically every weekday at 7:30 | `.\Install-VouchSchedule.ps1 -At 07:30 -UseVirtualDesktop` |
| Start the scheduled run now | `.\Install-VouchSchedule.ps1 -RunNow` |
| See how the scheduled runs went | `.\Install-VouchSchedule.ps1 -Status` |
| Stop the scheduled runs | `.\Install-VouchSchedule.ps1 -Uninstall` |

Capture list columns: **Name**, **Url**, **Steps** (optional: `clicktext:Words`,
`wait:3`, `click:#selector`, separated by `;`), **ScrollFullPage** (`Y`/`N`),
**Notes** (optional).

---

## Finding a selector

Only needed when `clicktext:` cannot tell two buttons apart.

1. Open the page in your normal Edge and press **F12**. A panel opens on the side.
2. Press **Ctrl+Shift+C**, then click the button or tab you want Vouch to click.
3. In the panel, the matching line is highlighted. Right-click it → **Copy** → **Copy
   selector**.
4. In your capture list, write `click:` and paste, for example `click:#tab-users`.
   Short selectors that start with `#` are the most reliable; if yours is very long
   (`body > div:nth-child(3) > …`), ask someone technical to shorten it.
5. Close the panel with **F12**.

---

## Words used in this guide

| Word | Meaning |
| --- | --- |
| **CSV** | A simple spreadsheet file (*comma-separated values*) that Excel and Notepad can open. |
| **URL** | A web page address, as shown in the browser's address bar. |
| **PowerShell 7** | A free Microsoft program for running commands; Vouch is written for it. |
| **Command window** | The window where you type commands (see [step 5](#5-open-the-vouch-command-window)). |
| **Report** | The `.html` file Vouch produces, with all screenshots inside. Opens in any browser. |
| **Hash / fingerprint (SHA-256)** | A 64-character code calculated from a file. The same file always gives the same code; any change gives a different one. |
| **Manifest hash** | One hash that covers all screenshots of a run together. |
| **Virtual desktop** | An extra, empty desktop Windows can show instead of your usual one (like a second screen you switch to). Vouch uses one so your other programs stay out of the pictures. |
| **Selector** | A precise description of one element on a web page, used by `click:` steps. |
| **Session / login expired** | The application has forgotten that you signed in; sign in again with `-LoginSetup`. |
