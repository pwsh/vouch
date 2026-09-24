# Examples

## live-test-2026-09-24

A real run of `tests\live\Invoke-LiveTest.ps1 -UseVirtualDesktop` against ten public
websites, on a 1280×800 Windows 11 desktop, 24 September 2026.

| File | What it is |
| --- | --- |
| `live-test.html` | The report, exactly as produced: open it in any browser. |
| `live-test.json` | The same results as JSON (`-JsonSummary`). File paths in it point to where the run wrote them. |
| `images\live-test\` | The 23 screenshots (`-SaveImages`) and their `SHA256SUMS`. |

What to look at:

- **Summary table** — six OK, one WARNING (a click step that cannot succeed), three
  FAILED (a 404 page, a 404 with an empty body, an unreachable host), each explained.
- **Integrity** — run ID, the manifest SHA-256, and every screenshot's hash.
- **Wikipedia – Audit** — one long article captured as 15 scroll segments.
- **Python.org / Hacker News** — click steps that open another page; the screenshot shows
  the page the click opened.
- **The taskbar** in every screenshot — the clock, and (because of `-UseVirtualDesktop`)
  no running application other than the capture browser; pinned icons remain.
- **An image's properties** — right-click any `.jpg` → *Properties → Details*: title,
  author, date taken, program and the full capture record in *Comments*.

Check that nothing has changed since the run:

```powershell
.\vouch.ps1 -Verify .\examples\live-test-2026-09-24\live-test.html
```

It should report `VERIFIED: 71 check(s) passed` (23 image hashes, 23 metadata checks,
23 saved files, the manifest and SHA256SUMS). Edit anything — an image, a hash, a capture
time — and it fails.

The run recorded the computer name and Windows user of the machine that made it, as
every Vouch report does.
