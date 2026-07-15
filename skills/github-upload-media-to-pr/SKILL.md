---
name: github-upload-media-to-pr
description: Upload images, GIFs, and video to a GitHub pull request's native user-attachments CDN from a headless or agent-driven browser session, then embed the resulting URLs in the PR body. Primary backend is Playwright (chromium.launchPersistentContext against a durable, one-time-authenticated profile), driving the PR comment box's file-upload staging area; gh (or gh-axi) applies the result. This is the only known path to a real inline-playing video in a PR body; images/GIFs can also go through it for a CDN-hosted link instead of a committed file. Use when asked to attach, embed, or upload a screenshot, GIF, or video to a PR so it renders inline, or when a committed-file link would only be a click-through rather than an inline preview. Falls back explicitly to instructing a committed-file link when no authenticated browser session is reachable or the upload fails; never produces a silent half-upload.
user-invocable: true
---

<!-- maintainers: this is the public, installer-facing skill. Keep it standalone, with no firstmate-internal paths, tools, or vocabulary; it must work the same whether firstmate spawned the caller or a human is driving it directly. -->

# github-upload-media-to-pr

Upload media to a GitHub PR the same way a human does when they drag a file into the web comment box, and embed the resulting CDN link in the PR body, all without ever submitting that comment.
This gets you a real inline-playing video, which no other hosting path (a committed file linked via `raw.githubusercontent.com`, a GitHub Actions artifact, a third-party host) can produce for a PR body.
For images and GIFs it is a nicer-to-have: a CDN link instead of a repo-bloating committed file, not a capability gap.

## Why this exists, and what it doesn't do

There is no public REST or GraphQL API for GitHub's native inline-attachment upload (the `user-attachments`/`user-images.githubusercontent.com` CDN a human gets by dragging a file into the web comment box).
This is a confirmed, long-standing platform gap, not a missing flag: `gh` CLI maintainers have repeatedly closed `gh issue create --attach`-style feature requests as blocked on the platform, and GitHub staff have not answered community requests for the same.
This skill routes around the gap by driving the same web UI a human uses, via browser automation against an already-authenticated session.

**This skill never authenticates on its own, and never reads, stores, or logs a `user_session` cookie.**
A cookie-authenticated POST straight to GitHub's undocumented `upload/policies/assets` endpoint is a known alternative technique (see prior art such as `lisonge/user-attachments`), and it is deliberately **not implemented here**: it is more brittle (an undocumented API, no stability guarantee) and more security-sensitive (harvesting and holding a session cookie) than driving the real UI through a browser tool that already manages the session for you.
If you find yourself reaching for a cookie or a raw POST to that endpoint to make this skill "just work" in some environment, stop - that is out of scope for this skill, not a shortcut to take.

## Backend: Playwright (primary), chrome-devtools-axi (documented alternative)

**Playwright is v1's primary backend.**
`chromium.launchPersistentContext(profileDir, { channel: 'chrome' })` drives Playwright's own Chromium/Chrome automation directly against a durable, one-time-authenticated profile directory, and `locator.setInputFiles(path)` sets files on the PR comment box's file input reliably, including while it is still hidden (`display:none`) - Playwright's `setInputFiles` does not require the target to be visible, unlike a click-driven upload.
`channel: 'chrome'` uses the machine's real, already-installed Google Chrome instead of Playwright's own bundled Chromium download, so no separate `npx playwright install` browser download is needed as long as Chrome is present; fall back to a bundled Chromium (`channel` omitted, after `npx playwright install chromium`) only if no system Chrome is available.

**`chrome-devtools-axi` is a documented alternative, not the default, because of an observed reliability gap.**
In verification for this skill, `chrome-devtools-axi upload @<uid> <path>` succeeded exactly once across many attempts (a plain public file-upload test page and a real GitHub PR), then failed silently on every subsequent attempt: no error, exit 0, but the target input's `.files` stayed empty. This held across headed/headless, default/named sessions, and ephemeral/persistent profiles, with clean process restarts in between, and could not be root-caused (no accessible error logs). If a future `chrome-devtools-axi` release closes this gap, or your environment demonstrates it works reliably, it remains a reasonable choice - the underlying technique (locate the file input, feed it, wait, harvest, clear) is identical either way, only the driving tool differs. Do not default to it without first confirming an upload actually lands (check the target input's `.files.length`, not just the command's exit code) - a `0` exit code from `chrome-devtools-axi upload` is **not** proof of success.

The rest of this skill is written for the Playwright backend.
If you use `chrome-devtools-axi` instead, adapt the same procedure: its `open`/`snapshot`/`eval`/`upload`/`wait`/`screenshot` commands map to Playwright's `page.goto`/`page.locator`/`page.evaluate`/`locator.setInputFiles`/`page.waitForTimeout`/`page.screenshot` one-for-one, but verify every upload actually attached a file before trusting it.

## Setup: a persistent authenticated profile (recommended, one-time)

The standing way to get an "already-authenticated browser" for a headless/agent context is a **dedicated, durable browser profile that only this skill uses**, not the operator's everyday personal browsing profile and not a fresh isolated profile per run.

1. **Pick a durable profile directory**, separate from any personal browsing profile, e.g. `<your-agent-home>/data/browser-profiles/github-media/`.
   Treat it as sensitive local state: never commit it, never copy it elsewhere, never print its contents.
2. **One-time interactive login.**
   Launch a **headed** (visible) browser against that profile and navigate to the login page:
   ```js
   const { chromium } = require('playwright');
   const ctx = await chromium.launchPersistentContext('<profile-dir>', { headless: false, channel: 'chrome' });
   const page = ctx.pages()[0] || await ctx.newPage();
   await page.goto('https://github.com/login');
   // leave ctx open; do not call ctx.close() until login is confirmed done
   ```
   A human completes the actual login (username/password, 2FA, SSO, or passkey - whatever the account requires) in that visible window.
   This skill and the agent driving it **never** type a password or drive a 2FA/passkey flow themselves - that is a human-only step every time it's needed, not something to automate around.
   Report that the window is up and waiting (e.g. a `needs-decision`-style signal in whatever supervision channel you use) and pause until a human confirms the login is complete.
3. **Reuse thereafter.**
   Once logged in, every later invocation reuses the same profile directory (`headless: true` is fine from here on, since the profile directory itself now carries the session).
   No further login is needed until the session actually expires.
4. **Never log cookie contents.**
   The profile directory is the credential; nothing about this skill's procedure reads, prints, or transmits `user_session` or any other cookie value out of that directory - see "Why this exists" above.
5. **When the session has expired**, Step 1 below will show a "Sign in to comment" link instead of a comment form - repeat the one-time interactive login (step 2 above) rather than treating it as a hard failure the first time; only fall back per "Clean failure and fallback" if a human isn't available to re-authenticate.

## Preconditions: check these before doing anything else

Verify every one of these before touching the PR page.
If any check fails, stop and report the specific failure per "Clean failure and fallback" below - do not attempt a partial upload or guess your way past a missing precondition.

1. **An authenticated browser session is reachable.**
   `launchPersistentContext` must point at the durable profile from "Setup" above.
   A freshly launched isolated/incognito context is **not** authenticated by default - confirm this concretely (see Step 1 below) rather than assuming it.
2. **`gh` (or `gh-axi`) is authenticated** against the repo that owns the PR, with at least write access to edit the PR body (or comment, if you're using Option B in Step 7).
3. **The media files are staged somewhere the browser process can actually read.**
   Verify this empirically in your environment rather than assuming it.
   When in doubt, stage inside the repository you're already working in, not `/tmp`.
4. **Filenames are simple.**
   No spaces or special characters.
   Copy to a simple name first if the source file has either.
5. **Files are within GitHub's caps.**
   10MB for images and GIFs; 10MB for video on a free plan, 100MB on paid.
   Check with `file` (type) and `ls -la` (size) before uploading, not after a failed/stalled upload.

## Supported media

Images: `png`, `jpg`, `jpeg`, `gif`, `webp`.
Video: `mp4`, `webm`, `mov`.

## Procedure

### Step 0 - Resolve the PR and validate inputs

Resolve the target PR's URL (ask the caller, or derive it with `gh pr view --json url` in the right repo).
Confirm each media file exists, has a simple filename, an allowed extension, and a size under the caps above.
Copy/rename into a safe staging location first if any of that isn't already true - never upload a file that fails these checks and hope GitHub sorts it out.

### Step 1 - Confirm you have a live, authenticated session

```js
const { chromium } = require('playwright');
const ctx = await chromium.launchPersistentContext('<profile-dir>', { headless: true, channel: 'chrome' });
const page = ctx.pages()[0] || await ctx.newPage();
await page.goto(prUrl, { waitUntil: 'domcontentloaded' });
const notAuthenticated = await page.getByRole('link', { name: 'Sign in to comment' }).count() > 0;
```
If `notAuthenticated` is true, you are **not** authenticated in this browser session.
Do not attempt to log in yourself (typing a password or driving 2FA/SSO/passkey flows is out of scope for this skill and is not "driving an already-authenticated session," which is the only mode this skill supports).
Stop and report per "Clean failure and fallback" below.
Otherwise the page has a real comment form and you can proceed.

### Step 2 - Locate the file-upload staging area

The comment form's file input lives near the bottom of the "Conversation" tab, historically at `#fc-new_comment_field`, nested inside a `file-attachment` element and usually hidden (`display:none`) until a human clicks the "Attach files" affordance.
Playwright's `setInputFiles` does not require the element to be visible, so you can target it directly without unhiding it first:
```js
const fileInput = page.locator('#fc-new_comment_field');
await fileInput.waitFor({ state: 'attached', timeout: 15000 });
```
If that selector doesn't resolve, fall back to a broader locator and confirm there's exactly one: `page.locator('input[type=file]')`.
This selector is the one documented by the two reference implementations this skill's technique is drawn from (`tonkotsuboy/github-upload-image-to-pr`, `jacobmassey/github-upload-media-to-pr`) as of when they were written, and independently verified live against a real GitHub PR while building this skill - treat it as a strong first guess, not a guaranteed constant.
See "DOM churn and recovery" below for what to do when it's wrong.

### Step 3 - Upload each file

For each staged file, in order:
```js
await fileInput.setInputFiles(mediaPath);
```
Then wait for GitHub's client-side uploader to finish before uploading the next file or reading the textarea:
```js
await page.waitForTimeout(imageOrVideo === 'video' ? 15000 : 5000);
```
- Images/GIFs: ~5s (up to 5s; images are typically faster).
- Video: 10-15s; larger files lean toward the long end.

You can chain multiple uploads into the same textarea before harvesting URLs (Step 4) - GitHub appends each finished upload to the textarea value in sequence; calling `setInputFiles` again on the same input for the next file does not clear what the previous upload already wrote into the textarea.

### Step 4 - Harvest the uploaded URLs from the textarea

Read the comment textarea's live value (do **not** submit the form):
```js
const textarea = page.locator('#new_comment_field');
const value = await textarea.inputValue();
```
GitHub injects the finished upload in one of two forms - handle both:

- **Images**: an HTML `<img>` tag, e.g. `<img width="..." alt="..." src="https://github.com/user-attachments/assets/<uuid>">`.
- **Video**: a bare URL on its own line, e.g. `https://github.com/user-attachments/assets/<uuid>`.

Extract every `https://github.com/user-attachments/assets/<uuid>` occurrence with a regex - you don't need a full markdown/HTML parser:
```js
const urls = [...new Set(value.match(/https:\/\/github\.com\/user-attachments\/assets\/[0-9a-f-]+/g) || [])];
```
These URLs are already live and persistent the moment the upload finishes - they do not require the comment to ever be submitted.

### Step 5 - Clear the textarea

Reset the field so nothing is left staged for a comment you never intend to post:
```js
await textarea.fill('');
```
Do not click any "Comment" / "Submit" button at any point in this procedure - the whole point of using the comment box is that it's a staging area you never actually post from.

### Step 6 - Compose the embed markdown

Build markdown from the harvested URLs, matched to what each media type needs to render inline:

- **Video**: a bare `https://github.com/user-attachments/assets/<uuid>` URL on its own line renders as an inline player.
  No wrapping markdown syntax needed - wrapping it in `![]()` or a link will break the inline player.
- **Image/GIF**: standard markdown image syntax `![description](https://github.com/user-attachments/assets/<uuid>)`, or an `<img src="..." width="...">` tag if you need explicit sizing.

Compose a short caption per item if the caller wants captions; keep it terse.

### Step 7 - Apply the result

Two ways, pick based on what the caller asked for:

- **Option A - edit the PR body directly** (default, matches "embed it in the PR"): `gh pr edit <PR> --body-file <path>` (or `gh-axi pr edit`) with the new section merged into the existing body.
  If the caller already has a compositor step for the PR body (something that assembles `## Summary` / `## How` / `## Evidence` sections), hand the composed markdown back to that step instead of editing the body yourself, so you don't clobber other sections it manages.
- **Option B - post as a PR comment**: `gh pr comment <PR> --body-file <path>` (or `gh-axi pr comment`), when the caller wants it as a comment rather than baked into the description.

### Step 8 - Verify

Reload the PR and screenshot the rendered body:
```js
await page.goto(prUrl, { waitUntil: 'domcontentloaded' });
await page.waitForTimeout(3000);
const videoRendered = await page.locator('video').count() > 0;
await page.screenshot({ path: outputPath, fullPage: true });
```
Confirm the image renders and, for video, that `videoRendered` is true - a real `<video>` element with playback controls in place, not a bare clickable link.
A bare link means the embed markdown was wrong (see Step 6) or the upload didn't actually land on the `user-attachments` CDN.
Always close the browser context when done: `await ctx.close();`.

## DOM churn and recovery

The selectors and structure this skill relies on (`file-attachment`, `#fc-new_comment_field`, `#new_comment_field`, the injected `<img>`/bare-URL forms) are an undocumented GitHub web UI surface, not a stable API.
GitHub can and does change this DOM with no deprecation notice.
Budget for occasional selector maintenance - this is expected upkeep, not a sign the technique is broken in principle.

When any step in "Procedure" doesn't match what you actually see:

1. **Re-inspect before anything else.**
   `await page.locator('input[type=file]').count()` and `await page.locator('input[type=file]').first().getAttribute('id')` (or a snapshot/DOM dump) to see the current structure around the comment form, rather than assuming the old selector is merely flaky.
2. **Re-derive the selector from what's actually there.**
   Look for the drop-zone/attach-files control's nearest `input[type=file]` ancestor-or-sibling, and the comment form's actual textarea id.
3. **If GitHub's upload UI has changed shape entirely** (not just a renamed id, but a different interaction model), stop and report it as a failure per "Clean failure and fallback" rather than guessing further - a wrong guess that silently uploads to the wrong place, or partially fills a form, is worse than a clean failure.
4. Update this skill file itself, once you've confirmed a new working selector/flow, so the next invocation doesn't rediscover it from scratch.

## Clean failure and fallback

If any precondition fails, or the procedure fails at any step (no authenticated session, upload never appears in the textarea, file exceeds size caps, DOM structure doesn't match and can't be recovered per above):

1. **Report the failure explicitly and specifically** - which precondition or step failed, and why, not just "upload failed."
2. **Never produce a silent half-upload.**
   If you uploaded some files but not others, or got a URL for the image but not the video, say exactly what succeeded and what didn't - don't embed a partial result and call it done.
   Verify an upload actually attached before trusting it (e.g. re-read the textarea and confirm it grew, or check the input's file count) - a tool call returning success is not proof the file landed; this is the exact failure mode observed with the `chrome-devtools-axi` backend (see "Backend" above).
3. **Instruct the caller to fall back to the committed-file floor**: commit the media file to the PR branch and link it via `raw.githubusercontent.com/<owner>/<repo>/<branch>/<path>` in standard markdown image syntax.
   This renders inline for images and animated GIFs, just not for video (an mp4/webm linked this way is a click-through, not an inline player - say so if that's the fallback you're recommending for a video).

This fallback is the deliberate, designed degradation path for this skill, not an afterthought - a caller with a media-embedding task should never be left with nothing just because a browser session or a selector wasn't available this time.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `page.goto` lands on a "Sign in to comment" page | No authenticated session reachable | Stop, report per "Clean failure and fallback" - do not attempt to log in yourself |
| `setInputFiles` throws or times out finding the input | Selector changed, or the input isn't attached yet | Re-inspect per "DOM churn and recovery"; ensure you waited for `state: 'attached'`, not `'visible'` |
| Upload never appears in the textarea | Didn't wait long enough, or the upload failed client-side | Re-check with a longer wait; re-inspect the DOM near the drop zone for an error toast/message |
| Video embedded but renders as a plain link, not a player | Wrapped the bare URL in `![]()` or a markdown link | Use the bare URL on its own line, unwrapped, per Step 6 |
| `gh pr edit` succeeds but the section you added is gone later | A later `no-mistakes`-style rebase/reformat step rewrote the body after your edit | Re-run this skill's embed step after any later body-rewriting step, not just once |
| `chromium.launch` fails with "Executable doesn't exist" | No bundled Chromium downloaded and no `channel: 'chrome'` | Pass `channel: 'chrome'` to use the system's installed Chrome, or run `npx playwright install chromium` once |
| `chrome-devtools-axi upload` returns exit 0 but the file never attaches | The observed reliability gap in that backend (see "Backend" above) | Switch to the Playwright backend, or verify `.files.length` directly before trusting the command's exit code |

## Notes for callers integrating this skill

- `user-attachments/assets/<uuid>` URLs are live and persistent the moment the client-side upload finishes - they do not depend on the comment ever being submitted, and they survive the textarea being cleared.
- This skill deliberately does not choose *whether* a given PR needs a floor (committed screenshot) or ceiling (this skill) treatment - that's the caller's call.
  This skill only handles the mechanics once the caller has decided to use it.
- Prefer Step 7 Option A folding into an existing body-compositor step over a raw `gh pr edit` when the caller already manages other PR-body sections, so you don't clobber them.
- A `playwright` package must be resolvable from wherever you run these scripts (`npm install playwright`, or an already-installed copy on the machine); `channel: 'chrome'` needs a real Google Chrome install but skips any Playwright browser download entirely.
