# QA Playbook: Think Like a Senior QA Engineer

> ### TL;DR - the 3 commands
>
> | When | Command | What it catches |
> |---|---|---|
> | Every commit (~1-3 min) | `powershell -ExecutionPolicy Bypass -File .\qa-check.ps1` | Mechanical bugs: format, lint, type errors, failing tests, leftover `debugger`, secrets, conflict markers |
> | Before PR / merge | `powershell -ExecutionPolicy Bypass -File .\qa-check.ps1 -Mode full -E2E` | The same, plus coverage, production build, vulnerable dependencies, end-to-end tests |
> | Any time you finish a feature | `/qa-review` in Claude Code | Logic bugs, CRUD data-flow bugs (list not updated after create/edit/delete), and requirement bugs that tools cannot see. It lists all positive and negative cases and tests every one. It also verifies acceptance criteria (ticked boxes are claims, not proof) and reviews test quality. `/qa-review --fix` fixes confirmed bugs and adds a regression test for each |
>
> - The script catches **mechanical** bugs.
> - `/qa-review` catches **logic and requirement** bugs.
> - The checklist in this document catches **what both miss**.

---

## Table of contents

1. [Setup (one time)](#1-setup-one-time)
2. [How a senior QA engineer thinks](#2-how-a-senior-qa-engineer-thinks)
3. [Feature vs module vs project](#3-feature-vs-module-vs-project)
4. [The review checklist](#4-the-review-checklist)
5. [Edge-case cheat sheet](#5-edge-case-cheat-sheet)
6. [Test design](#6-test-design)
7. [Exploratory testing in 30 minutes](#7-exploratory-testing-in-30-minutes)
8. [Bug report template](#8-bug-report-template)
9. [Definition of Done](#9-definition-of-done)
10. [Daily workflow](#10-daily-workflow)

---

## 1. Setup (one time)

### 1.1 Put the script in your repo

1. The script is at `skills/qa-review/scripts/qa-check.ps1` in the qa-skills repo. Copy it into your project root (or `scripts/`). To download it with PowerShell:

   ```powershell
   Invoke-WebRequest https://raw.githubusercontent.com/mamunr412/qa-skills/main/skills/qa-review/scripts/qa-check.ps1 -OutFile qa-check.ps1
   ```

   Note: `/qa-review` also works without copying, because the skill ships its own copy of the script.
2. Add `.qa/` to `.gitignore`. The script writes logs and reports there.

```bash
echo ".qa/" >> .gitignore
```

### 1.2 Add npm scripts

The gate looks for these `package.json` scripts. If one is missing, it falls back to `npx prettier --check .`, `npx eslint .` or `npx tsc --noEmit`. If a tool is not installed, that stage is SKIP.

```json
{
  "scripts": {
    "dev": "next dev",
    "build": "next build",
    "lint": "eslint .",
    "typecheck": "tsc --noEmit",
    "format:check": "prettier --check .",
    "test": "vitest run",
    "test:coverage": "vitest run --coverage",
    "test:e2e": "playwright test",
    "qa": "powershell -ExecutionPolicy Bypass -File ./qa-check.ps1",
    "qa:full": "powershell -ExecutionPolicy Bypass -File ./qa-check.ps1 -Mode full"
  }
}
```

Notes:
- Use Jest instead of Vitest if your project already uses it. Any runner works.
- The script also accepts `type-check` instead of `typecheck`, and `test:unit` instead of `test`.
- Now you can run `npm run qa` and `npm run qa:full`.

### 1.3 Install the `/qa-review` skill

**Option 1 (recommended): the skills CLI.**

```bash
npx skills add mamunr412/qa-skills --skill qa-review
```

This installs the skill for Claude Code and other agents. See `npx skills --help` for global install (all projects).

**Option 2: manual.** Clone the repo and copy the whole `skills/qa-review/` folder:

| Where | Folder to copy | Effect |
|---|---|---|
| This project only | `skills/qa-review/` to `.claude/skills/qa-review/` | `/qa-review` works in this repo |
| All projects | `skills/qa-review/` to `%USERPROFILE%\.claude\skills\qa-review\` | `/qa-review` works everywhere |

```powershell
git clone https://github.com/mamunr412/qa-skills.git
cd qa-skills

# This project only (run from your project, adjust the clone path)
New-Item -ItemType Directory -Force .claude\skills
Copy-Item -Recurse -Force .\skills\qa-review .claude\skills
# All projects
New-Item -ItemType Directory -Force "$env:USERPROFILE\.claude\skills"
Copy-Item -Recurse -Force .\skills\qa-review "$env:USERPROFILE\.claude\skills\"
```

Restart Claude Code, then type `/qa-review` to test it.

Arguments for `/qa-review`:

| Argument | What it does |
|---|---|
| (none) | Reviews the changes on the current branch |
| `<path>` | Reviews that module or folder and its consumers |
| `<PR number>` | Reviews that pull request (diff and description) |
| `<ticket/issue URL or number>` | Reads the ticket and uses its acceptance criteria |
| `"feature description"` | Finds the code for that feature and reviews it |
| `--full` | Whole project or release review, with the full gate |
| `--write-tests` | Writes and runs automated tests for every case |
| `--fix` | Fixes confirmed bugs, adds a regression test for each, never commits |

Arguments can be combined, for example `/qa-review 123 --fix`.

### 1.4 Optional: git pre-push hook

This runs the quick gate before every `git push`. A failure blocks the push.

Create `.git/hooks/pre-push` (no file extension):

```bash
#!/bin/sh
echo "Running QA gate before push..."
powershell -NoProfile -ExecutionPolicy Bypass -File ./qa-check.ps1
status=$?
if [ $status -ne 0 ]; then
  echo "QA gate failed. Push blocked. See .qa/qa-report.md"
  exit 1
fi
exit 0
```

Husky alternative (the hook is stored in the repo, so the whole team gets it):

```bash
npx husky init
```

Then put this line in `.husky/pre-push`:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File ./qa-check.ps1
```

Emergency skip (use rarely, and tell your team): `git push --no-verify`.

### 1.5 Optional: GitHub Actions

`.github/workflows/qa.yml`:

```yaml
name: QA gate
on:
  pull_request:
  push:
    branches: [main]

jobs:
  qa:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0   # needed so the diff against the base branch works
      - uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: npm
      - run: npm ci
      - name: Run QA gate
        shell: pwsh
        run: ./qa-check.ps1 -Mode full
      - name: Upload QA report
        if: failure()
        uses: actions/upload-artifact@v4
        with:
          name: qa-report
          path: .qa/
```

Add `-E2E` to the command if your CI has browsers installed (for Playwright: add a `npx playwright install --with-deps` step).

### 1.6 Command reference

Full syntax:

```powershell
.\qa-check.ps1 [-Path <dir>] [-Mode quick|full] [-Base <branch>] [-E2E] [-SkipAudit] [-FailFast] [-ShowOutput]
```

| Flag | What it does | When to use it |
|---|---|---|
| `-Path <dir>` | Run the gate on this folder instead of the current one. Hygiene checks only this folder. If the folder has no project file (for example `src\modules\billing` has no `package.json`), lint, typecheck and tests run for the nearest parent project, and the output shows `Tools at: <folder>` | Check one module or one package in a monorepo |
| `-Mode quick` | Default. Stages 1-5: Hygiene, Format, Lint, Typecheck, Unit tests | Every commit |
| `-Mode full` | Quick stages, plus coverage on tests, 6 Build, 7 Audit, 8 E2E (E2E only with `-E2E`) | Before PR, before merge, before release |
| `-Base <branch>` | Branch to compare against for the Hygiene check on changed files | Your base is not `main` (for example `develop`) |
| `-E2E` | Turns on stage 8, end-to-end tests (full mode) | Before PR / merge |
| `-SkipAudit` | Skips stage 7, dependency vulnerability audit | Offline, or a known vulnerability you already accepted |
| `-FailFast` | Stop at the first FAIL | You want a quick answer and will fix one thing at a time |
| `-ShowOutput` | Print the output of each step on screen (it is always saved in `.qa/logs/`) | Debugging why a step fails |

The default `-Base` is auto-detected: `origin/main`, `main`, `origin/master`, `master`.

Examples:

```powershell
# Daily
powershell -ExecutionPolicy Bypass -File .\qa-check.ps1

# Only one module
powershell -ExecutionPolicy Bypass -File .\qa-check.ps1 -Path .\src\modules\billing

# Before a PR
powershell -ExecutionPolicy Bypass -File .\qa-check.ps1 -Mode full -E2E

# Base branch is develop, show output, stop at first failure
powershell -ExecutionPolicy Bypass -File .\qa-check.ps1 -Base develop -FailFast -ShowOutput

# PowerShell 7 works too
pwsh -File .\qa-check.ps1 -Mode full

# Built-in help
Get-Help .\qa-check.ps1 -Full
```

### 1.7 What the stages do

| # | Stage | Mode | What it checks |
|---|---|---|---|
| 1 | Hygiene | quick, full | Changed files (vs base branch, or all files if not a git repo). See table below. |
| 2 | Format | quick, full | `format:check`, or `npx prettier --check .` |
| 3 | Lint | quick, full | `lint`, or `npx eslint .` |
| 4 | Typecheck | quick, full | `typecheck` / `type-check`, or `npx tsc --noEmit` |
| 5 | Unit tests | quick, full | `test:unit` or `test`. In full mode: `test:coverage`. Runs with `CI=true`. |
| 6 | Build | full | `build` |
| 7 | Audit | full | Dependency vulnerabilities. Skipped with `-SkipAudit`. |
| 8 | E2E | full + `-E2E` | `test:e2e` |

Hygiene rules:

| Result | What it finds |
|---|---|
| FAIL | Merge conflict markers |
| FAIL | Focused tests: `.only(`, `fit(` |
| FAIL | `debugger;`, `breakpoint()` |
| FAIL | Likely secrets: AWS keys, private keys, `sk-` tokens, GitHub/Slack tokens, hardcoded `password` / `api_key` strings, a committed `.env` |
| FAIL | Anything `gitleaks` finds (only if gitleaks is installed) |
| WARN | `console.log` in non-test code |
| WARN | New `TODO` / `FIXME` |
| WARN | Files larger than 1 MB |

Other stacks are detected automatically: Python (ruff/black, ruff/flake8, mypy, pytest, pip-audit), Go, Rust, .NET, Java (Maven/Gradle). The package manager (npm, pnpm, yarn, bun) is chosen by the lockfile.

### 1.8 Reading the result

| Label | Meaning | What you do |
|---|---|---|
| PASS | The check ran and found no problem | Nothing |
| FAIL | The check ran and found a problem | Fix it. Read `.qa/logs/` for the step. |
| WARN | Not blocking, but suspicious | Fix it, or write down why it is fine |
| SKIP | The check did not run (tool or script missing, or a flag turned it off) | Install the tool. Until then, that layer is **unchecked**. |

| Verdict | Meaning | Exit code |
|---|---|---|
| READY TO PUSH | No FAIL, no WARN | 0 |
| READY WITH WARNINGS | No FAIL, some WARN | 0 |
| NOT READY | At least one FAIL | 1 |

Where to look:

| What | Where |
|---|---|
| Summary report (Markdown) | `.qa/qa-report.md` |
| Output of each step | `.qa/logs/` |

A SKIP is not a PASS. If lint is SKIP, nobody checked lint.

---

## 2. How a senior QA engineer thinks

### 2.1 Mindset

> **My job is not to prove it works. My job is to find how it fails before the user does.**

| Junior habit | Senior habit |
|---|---|
| "It works on my machine." | "It works with my data. What about other data?" |
| Tests the happy path | Tests the happy path last |
| Counts tests | Counts risks covered |
| Trusts the code, the comments, the ticket | Trusts evidence: a run, a log, a screenshot |
| Asks "does it work?" | Asks "how can it break, and how bad is it?" |
| Tests what the developer built | Tests what the user needs |
| Finds a bug, stops | Finds a bug, asks "what else is near it?" (bugs cluster) |
| "Ticked box = done" | "Ticked box = a claim. Show me the evidence." |

Three rules:
1. **Assume nothing.** Check the claim yourself.
2. **Trust evidence.** "I think it works" is not a test result.
3. **Think in risk, not in test count.** 5 tests on money logic beat 50 tests on a tooltip.

### 2.2 The 7 questions to ask before testing anything

| # | Question | Why it matters | Example (checkout discount code) |
|---|---|---|---|
| 1 | **What changed?** And what did it touch indirectly? | Bugs hide in neighbours | Price calculation is shared with invoices and refunds |
| 2 | **Who uses it, and how?** | Real users do strange things | Mobile users, double-tappers, users with two tabs |
| 3 | **What is the worst thing that can happen?** (data loss, money, security, legal, trust) | Sets how deep you test | Customer pays the wrong amount. Legal and trust problem. |
| 4 | **What are the inputs and states?** | Every input and state is a test | Code text, cart total, user, time, code status |
| 5 | **What depends on it, and what does it depend on?** | Failures travel along dependencies | Payment API, tax rules, currency rounding, email receipts |
| 6 | **How will we know it broke in production?** | A bug nobody sees lives longer | Log on every rejected code, alert on spike of errors |
| 7 | **How do we roll back?** | Every release can fail | Feature flag. Is the DB migration reversible? |

If you cannot answer a question, that is your first finding.

### 2.3 Risk-based testing

You cannot test everything. Test the risky things first and deepest.

**Risk = Likelihood x Impact**

|  | Impact LOW | Impact MEDIUM | Impact HIGH |
|---|---|---|---|
| **Likelihood HIGH** | Light check | **Deep test** | **Deepest test, automate** |
| **Likelihood MEDIUM** | Skip or light | Normal test | **Deep test** |
| **Likelihood LOW** | Skip | Light check | Normal test + monitoring |

Signals of **high likelihood** of bugs:

- New code (not battle-tested)
- Complex logic, many `if` branches, deep nesting
- Money, dates, time zones, permissions
- Concurrency (two users, two tabs, background jobs)
- Code that changes often (look at `git log`)
- Third-party APIs (they fail and change)
- Hurried work, no review, late Friday changes
- Code the author says "is simple"

Signals of **high impact**: money, personal data, login and permissions, the main user flow, anything that cannot be undone, anything legal.

### 2.4 Heuristics senior QAs use

A heuristic is a rule of thumb that helps you find bugs. Use many of them. They overlap on purpose.

#### SFDIPOT (Structure, Function, Data, Interfaces, Platform, Operations, Time)

From James Bach's Heuristic Test Strategy Model. Walk through each letter for your feature.

| Letter | Ask | Examples |
|---|---|---|
| **S**tructure | What is it made of? | Which files, components, services, DB tables? Is a shared helper used elsewhere? |
| **F**unction | What does it do? | Every action, every calculation, every error message |
| **D**ata | What data goes in, out, is stored? | Valid, invalid, empty, huge, old data already in the DB |
| **I**nterfaces | How does it talk to others? | UI, REST API, webhooks, third-party APIs, files, emails |
| **P**latform | What does it run on? | Chrome/Safari/Firefox, mobile, Node version, OS, screen size |
| **O**perations | How is it really used? | Normal users, admins, bulk use, rare flows, upgrades, failures |
| **T**ime | When does it matter? | Time zones, DST, timeouts, expiry, order of events, "at the same time" |

#### The other heuristics

| Heuristic | Meaning | Concrete examples |
|---|---|---|
| **CRUD** | Test Create, Read, Update, Delete for every entity | Create an order, read it in list and detail, edit it, delete it. After delete, does the detail URL show 404 and not a crash? |
| **Zero / One / Many** | Behaviour changes at 0, 1 and many items | Empty cart; one item ("1 items" typo?); 10,000 items (slow? pagination?) |
| **Boundaries** | Test min-1, min, max, max+1 | Name max 50 chars: try 49, 50, 51. Age 18-65: try 17, 18, 65, 66. Quantity 1-99: try 0, 1, 99, 100. |
| **Goldilocks** | Too small, too big, just right | Image upload: 1 KB, 50 MB, 500 KB. Password: 1 char, 5,000 chars, 12 chars. |
| **Interrupt** | Interrupt the flow in the middle | Refresh during submit; press Back after submit; lose network; double-click the button; close the tab mid-upload |
| **State transitions** | Test every state change, allowed and not allowed | Order: pending -> paid -> shipped. Can you go shipped -> pending? Can you pay twice? |
| **Follow the data** | Trace one value from input to output | Enter a name -> saved in DB -> shown in profile -> shown in email -> exported in CSV. Is it still correct (and escaped) at every step? |
| **Permissions / roles** | Test each role, and no role | Admin, normal user, guest, user from another company, deleted user. Call the API directly without the UI. |
| **Concurrency** | Two actors at the same time | Two tabs edit the same record; two users buy the last item; double submit |
| **Configuration / environment** | Change the setup | Missing env var; different locale; feature flag on and off; dev vs production URL |
| **Undo / recover** | What happens after a mistake or crash? | Delete by mistake: can you restore? Failed payment: is the cart still there? Crash mid-save: is data half-written? |

---

## 3. Feature vs module vs project

The scope changes what you ask and how deep you go.

| Scope | Main question | What to focus on | Typical tests | Command |
|---|---|---|---|---|
| **Feature** (one change, one PR) | Does it meet the acceptance criteria, and not break its neighbours? | Acceptance criteria, edge cases, UI states, the callers of changed code | Unit tests for logic, a few integration tests, quick manual check | `.\qa-check.ps1` then `/qa-review` (reviews the diff) |
| **Module** (a part with an interface: billing, auth, search) | Do the contracts hold, and do all consumers still work? | Interfaces and contracts, errors between parts, integration, regression of every consumer | Contract tests, integration tests, API tests, regression suite | `.\qa-check.ps1 -Path .\src\modules\billing -Mode full` then `/qa-review src/modules/billing` |
| **Project / release** | Does the whole product work for real users, and can we ship and undo it safely? | End-to-end user journeys; non-functional: performance, security, accessibility, compatibility; upgrade and data migration; rollback | E2E journeys, load test, security scan, accessibility audit, smoke test in staging, manual exploratory | `.\qa-check.ps1 -Mode full -E2E` then `/qa-review --full`, plus manual exploratory and the release checklist |

Extra points per scope:

**Feature**
- Read the diff, then read the callers.
- Test what the feature is NOT supposed to do ("negative" tests).
- Check that old behaviour next to it still works.

**Module**
- List every consumer of the module (search for imports).
- Check what happens when the module gets bad input, or its dependency fails.
- Check that a change in the module's output shape does not break callers (TypeScript helps; runtime data does not obey types).

**Project / release**
- Walk the top 5 user journeys end to end on staging, with realistic data.
- Run the upgrade path: old version with real data -> new version.
- Write down the rollback steps before you ship. Test them if you can.
- Check logs and dashboards after the release (first 30 minutes).

---

## 4. The review checklist

Copy this into your PR description. Tick what is true. Write "N/A" with a reason for the rest.

### 4.1 Requirements and acceptance criteria

- [ ] I can say in one sentence what the feature must do and for whom
- [ ] Acceptance criteria are written down (or I wrote them and the owner agreed)
- [ ] Each criterion has at least one test (automated or manual)
- [ ] I know what is out of scope
- [ ] Unclear requirements were clarified, not guessed
- [ ] Error messages and empty-state texts are decided (not "TODO")
- [ ] I checked the feature against the design / mockup

### 4.2 Functional

- [ ] Happy path works from start to finish
- [ ] Alternative paths work (other options, optional fields skipped)
- [ ] Every error path shows a clear message and leaves the system in a safe state
- [ ] Cancel, back and close do not leave half-saved data
- [ ] Repeating the action (double click, refresh, retry) does no harm
- [ ] The feature still works after reload and after logout / login
- [ ] Features that share code with this one still work (regression)
- [ ] The behaviour is the same on first use and on 100th use

### 4.3 Input and data validation

- [ ] Every input has a type, min, max and required rule
- [ ] Validation exists on the **server**, not only in the browser
- [ ] Empty, spaces-only, very long and special-character inputs are handled
- [ ] Numbers: 0, negative, decimals, huge values are handled
- [ ] Dates: invalid, past, future, time zone, DST are handled
- [ ] Uploaded files: size, type (by content, not only extension), name are checked
- [ ] Output is escaped when shown (HTML, CSV, email, logs)
- [ ] Error messages say what is wrong and how to fix it, without leaking internals

### 4.4 UI / UX

- [ ] **Loading** state exists (spinner or skeleton)
- [ ] **Empty** state exists (zero items: message and next step)
- [ ] **Error** state exists (with a retry action)
- [ ] **Success** state exists (the user knows it worked)
- [ ] Buttons are disabled (or guarded) while submitting, so no double submit
- [ ] Long text does not break the layout (names, titles, German words, URLs)
- [ ] Layout works at 320 px, tablet and large desktop
- [ ] Keyboard only: Tab order is logical, Enter submits, Esc closes dialogs
- [ ] Focus moves correctly (into a dialog, back after it closes, to the first error)
- [ ] Unsaved changes: a warning before leaving the page
- [ ] No layout jump when data loads

### 4.5 API and backend

- [ ] Status codes are correct (200/201/204, 400, 401, 403, 404, 409, 422, 429, 500)
- [ ] Validation on the server for every field, with clear errors
- [ ] Idempotency: a repeated POST (retry, double click) does not create a duplicate
- [ ] Pagination, filtering and sorting have limits and stable order
- [ ] Timeouts are set on every outgoing call
- [ ] Retries have a limit and a back-off, and only for safe operations
- [ ] Third-party failure (500, timeout, bad JSON) is handled
- [ ] Response shape does not change for existing clients (backward compatible)
- [ ] Errors are logged with context, and the user gets a safe message
- [ ] Async work (queues, jobs) can be retried without side effects

### 4.6 Data and database

- [ ] Migrations run on a copy of real data, not only on an empty DB
- [ ] Migrations are reversible (or the rollback plan is written down)
- [ ] Null and missing values are handled in code and in schema
- [ ] Unique constraints and foreign keys exist where the business rule needs them
- [ ] Multi-step writes use a transaction
- [ ] Deleting data: soft or hard delete is a conscious choice; related records are handled
- [ ] Indexes exist for the new queries
- [ ] Old data (created before this feature) still displays and works
- [ ] Backups / restore are not broken by the change

### 4.7 Security

(See the OWASP Top 10 for the full list of web risks.)

- [ ] **Authorization on every endpoint and action** (not only hiding buttons)
- [ ] **IDOR:** changing an id in the URL or body does not show another user's data
- [ ] **XSS:** user text is escaped; no `dangerouslySetInnerHTML` with user data
- [ ] **Injection:** SQL / NoSQL / command inputs use parameters, never string concatenation
- [ ] No secrets in code, in logs, in the browser bundle, or in git history
- [ ] Rate limiting on login, signup, password reset, and expensive endpoints
- [ ] No personal data (PII), tokens or passwords in logs or error messages
- [ ] Sessions and tokens expire; logout really invalidates them
- [ ] CSRF protection for cookie-based auth
- [ ] File uploads cannot run code or overwrite other files
- [ ] New dependencies were checked (`-Mode full` runs the audit)

### 4.8 Performance

- [ ] No N+1 queries (a query inside a loop)
- [ ] Large lists use pagination or virtualization
- [ ] Heavy work is not done on every render (`useMemo`, move to server)
- [ ] No infinite re-render or fetch loops (check `useEffect` dependencies)
- [ ] Bundle size did not grow a lot (check the build output)
- [ ] Images are sized and lazy-loaded
- [ ] Slow network (3G) still gives a usable page
- [ ] Caching is correct: no stale data shown after an update

### 4.9 Accessibility

- [ ] Every input has a visible label (not only a placeholder)
- [ ] Every image has meaningful `alt` text (or empty `alt` if decorative)
- [ ] Color contrast is at least 4.5:1 for normal text
- [ ] Everything works with keyboard only; the focus outline is visible
- [ ] Screen reader (NVDA is free on Windows) reads the page in a sensible order
- [ ] Errors and live updates are announced (`aria-live`, `role="alert"`)
- [ ] Information is not shown by color alone
- [ ] Buttons are `<button>`, links are `<a>`, headings are in order

### 4.10 Compatibility

- [ ] Latest Chrome, Firefox, Safari and Edge
- [ ] A real phone (iOS Safari and Android Chrome), not only the dev-tools emulator
- [ ] Time zones: user in UTC+14, UTC-12, and a DST change day
- [ ] Locales: date, number and currency formats (1,5 vs 1.5)
- [ ] RTL languages (Arabic, Hebrew) do not break the layout
- [ ] Non-ASCII names and text (accents, emoji, CJK)
- [ ] JavaScript errors do not blank the whole page (error boundaries)

### 4.11 Observability

- [ ] Important actions and failures are logged with enough context (request id, user id, not PII)
- [ ] Errors are sent to an error tracker (Sentry or similar)
- [ ] There is a metric or alert for the thing that would hurt most
- [ ] Logs do not contain secrets
- [ ] I know where to look first if a user reports "it does not work"

### 4.12 Release

- [ ] Behind a feature flag, or can be reverted by one `git revert`
- [ ] Rollback steps are written (including database)
- [ ] New environment variables are added to all environments and documented
- [ ] README / docs / API docs are updated
- [ ] Changelog entry is written
- [ ] Support and other teams know about user-visible changes
- [ ] Plan to watch logs and metrics after release

### 4.13 CRUD data flow (check this for every action button)

Most bugs in apps with lists and forms are here: the data saves, but the screen does not update.

| Action | Positive (must work) | Negative (must fail safely) |
|---|---|---|
| Create | New item appears in the list without manual refresh. It is still there after reload. Detail page shows correct values. Counts, badges and totals update. Item is in the right sort position and on the right page. Form resets or closes. | Server or validation error: the list is NOT changed (or the optimistic update is rolled back) and the user sees a message. Double submit does not create a duplicate. |
| Edit | List, detail and every other place that shows the item show the new value. It is still there after reload. Unchanged fields are not wiped. No duplicate is created. | Server or validation error: old value stays everywhere (or is rolled back) and the user sees a message. |
| Delete | Item disappears from the list. Counts update. Its detail URL shows "not found", not a crash. Related data is handled. A confirm step exists for destructive deletes. | Cancel leaves the item untouched. Server error: the item stays in the list and the user sees a message. |
| Get / List | Correct data for this user only. Empty, loading and error states exist. Pagination, sorting, filter and search are still correct after create, edit and delete. | Server error shows an error state with retry, not a blank page. Another user's data is never shown. |

- [ ] After every create/edit/delete, I checked the list, the detail page and the counts
- [ ] I reloaded the page and the change is still there
- [ ] I tested the failure path: server error leaves the list unchanged
- [ ] I found the refresh code (`invalidateQueries` / `router.refresh` / `revalidatePath` / `mutate`) and it uses the right key
- [ ] Two tabs: change in one tab, the other tab updates or shows fresh data after refresh
- [ ] Deleting the last item on a page does not show an empty page
- [ ] Every positive and negative case was tested, not only the important ones

---

## 5. Edge-case cheat sheet

Copy these values into forms, API calls and tests. Most real bugs come from a few of them.

### 5.1 Strings

| Test value | What it finds |
|---|---|
| `""` (empty) | Missing "required" check, crash on `.trim()` of undefined |
| `"   "` (spaces only) | "Required" check that counts spaces as text |
| `"a"` (1 char) | Minimum length rules |
| 10,000 characters | Layout break, DB column limit, slow regex, request size limit |
| `"👍🏽"` (emoji with skin tone) | Wrong length, cut in half, DB encoding (utf8 vs utf8mb4) |
| `"مرحبا"` (Arabic, RTL) | RTL layout, mixed direction text, wrong alignment |
| `"abc<script>alert(1)</script>"` | XSS |
| `' OR 1=1 --` | SQL injection |
| `" leading and trailing "` | Missing `trim`, duplicate "same" users |
| `"line1\nline2"` (newline) | Single-line fields, CSV export, log injection |
| `"O'Brien"`, `"Zoë"`, `"李雷"` | Quotes, accents, CJK names |
| `"Admin"` vs `"admin"` | Case-sensitive duplicates |

### 5.2 Numbers

| Test value | What it finds |
|---|---|
| `0` | Divide by zero, "falsy" bug (`if (!qty)` treats 0 as missing) |
| `-1` | Missing negative check (negative price, negative quantity) |
| `0.1 + 0.2` | Floating point: `0.30000000000000004`. Use integer cents for money. |
| `9007199254740993` (above `Number.MAX_SAFE_INTEGER`) | Lost precision in JSON and JS |
| `NaN`, `Infinity` | Failed parse passed through, shown as "NaN" |
| `"1,5"` (decimal comma) | Locale parsing |
| `1e21`, `"1e3"` | Exponent formats |
| `"12abc"` | `parseInt` accepts it, `Number` does not |
| `0.005`, `2.675` | Rounding differences (`toFixed`) |

### 5.3 Dates and time

| Test value | What it finds |
|---|---|
| Feb 29 (leap year), and Feb 29 of a non-leap year | Invalid date accepted or crash |
| Dec 31 -> Jan 1 | Year rollover, week numbers, "this year" filters |
| Day of DST change (23 or 25 hours) | Wrong duration, duplicated or missing hour |
| User in UTC+14 and UTC-12 | Date shows as the wrong day |
| Midnight, 23:59:59 | End-of-day boundaries, "today" filters |
| Past date, far future date (year 2100) | Missing range checks, expiry bugs |
| `"2026-13-40"` | Invalid date accepted (`new Date()` may give `Invalid Date`) |
| `"2026-02-30"` | JS may roll over to March 2 silently |
| Server time vs browser time | "Expires today" differs by place |

### 5.4 Lists and collections

| Test value | What it finds |
|---|---|
| 0 items | Empty state missing, `items[0]` crash, `reduce` without initial value |
| 1 item | Singular/plural text, "next" button logic |
| Many items (10k) | Slow render, no pagination, timeouts |
| Duplicates | Duplicate keys in React, unique constraint errors |
| Unsorted / reverse-sorted | Assumed sort order |
| Exactly page-size items (10, 20, 100) | Off-by-one in pagination, empty last page |
| Item deleted while list is open | Stale list, 404 on click |

### 5.5 Files

| Test value | What it finds |
|---|---|
| 0 bytes | Crash on parse |
| Huge file (1 GB) | No size limit, timeout, memory |
| Wrong extension (`.jpg` that is a text file) | Check by extension only |
| Renamed `.exe` as `.png` | Security risk, type not checked by content |
| Unicode file name (`résumé 日本語.pdf`) | Encoding bugs in storage and download headers |
| Name with spaces, `#`, `%`, `..\` | URL encoding, path traversal |
| Same file uploaded twice | Overwrite or duplicate handling |
| Upload cancelled halfway | Orphan files |

### 5.6 Network

| Test value | What it finds |
|---|---|
| Slow 3G (browser dev tools throttling) | Missing loading states, timeouts |
| Offline (dev tools or unplug) | Unhandled fetch error, endless spinner |
| Request timeout | No timeout set, UI stuck |
| Server `500` | Error state missing, raw error shown |
| `401` (expired session) in the middle of work | Lost form data, redirect loop |
| `403`, `404`, `429` | Wrong or missing messages |
| Same request sent twice | Duplicates (orders, payments, emails) |
| Response arrives out of order | Old response overwrites new one |
| Invalid JSON or an empty body in the response | Crash on `.json()` |

### 5.7 Users and permissions

| Test value | What it finds |
|---|---|
| User without permission | Missing server-side authorization |
| Deleted or disabled user with an open session | Still has access |
| Two tabs, same user | Stale state, logout in one tab |
| Two users on the same record | Lost update (last write wins silently) |
| User from another company / tenant | Data leak (IDOR) |
| Brand-new user with no data | Empty states, null profile fields |
| Very old user with legacy data | Old format breaks new code |

---

## 6. Test design

### 6.1 The test pyramid

```
        /\
       /E2E\          few     slow, expensive, close to real use
      /------\
     /Integr. \       some    parts working together
    /----------\
   /   Unit     \     many    fast, cheap, precise
  /--------------\
```

| Level | Cover | Do not cover | Example |
|---|---|---|---|
| **Unit** (many) | Pure logic: calculations, validation, formatters, reducers, hooks, branches | Network, DB, real browser | `applyDiscount(total, code)` returns the right total |
| **Integration** (some) | Parts together: API route + DB, component + data fetching, module contracts | Every small branch (leave to unit tests) | `POST /api/discounts/apply` writes the right DB rows |
| **E2E** (few) | The top user journeys in a real browser | Edge cases (too slow); anything unit tests can do | User logs in, adds an item, applies a code, pays |

If a bug is found by E2E, add a unit test too, so you find it faster next time.

### 6.2 A good test

- [ ] Tests **one behaviour**
- [ ] **Independent**: does not depend on other tests or their order
- [ ] **Deterministic**: same result every time (no real clock, no random, no real network)
- [ ] **Clear name**: reads like a sentence, e.g. `rejects an expired discount code`
- [ ] Tests **behaviour, not implementation**: it should not break when you refactor
- [ ] Fails for the right reason (you saw it fail once before it passed)
- [ ] Short and readable: Given / When / Then

Bad: `test('works')`. Good: `test('shows an error when the discount code is expired')`.

### 6.3 Writing test cases: Given / When / Then

- **Given**: the starting state
- **When**: the action
- **Then**: the expected result

Worked example: **"Apply discount code at checkout"**

Rules of the feature (assumed): one code per order; code is case-insensitive; code has an expiry date; a code can be used once per user; the discount cannot make the total negative; money is in cents.

| ID | Type | Given / When / Then | Priority |
|---|---|---|---|
| TC-01 | Positive | **Given** cart total 100.00 and valid code `SAVE10` (10%). **When** user applies it. **Then** total is 90.00 and the discount line shows -10.00. | High |
| TC-02 | Negative | **Given** code `OLD20` expired yesterday. **When** user applies it. **Then** error "This code has expired", total stays 100.00. | High |
| TC-03 | Negative | **Given** user already used `ONCE5` in a past order. **When** user applies it again. **Then** error "Code already used", total unchanged. | High |
| TC-04 | Edge | **Given** valid code `SAVE10`. **When** user types `save10`, `SAVE10`, ` Save10 ` (with spaces). **Then** all are accepted and give the same discount. | Medium |
| TC-05 | Edge | **Given** cart total 5.00 and code `TAKE20` (fixed 20.00 off). **When** user applies it. **Then** total is 0.00, never negative. | High |
| TC-06 | Edge / concurrency | **Given** valid code, user has the checkout open in two tabs. **When** user clicks "Apply" in both tabs at the same time (or double-clicks). **Then** the discount is applied once; the usage count goes up by 1. | High |
| TC-07 | Edge | **Given** cart total 33.33 and code `SAVE15` (15%). **When** applied. **Then** discount is 5.00 (rounded to cent by the agreed rule), total 28.33, and the amounts add up exactly (no 0.01 gap). | High |
| TC-08 | Negative | **Given** unknown code `XXXX`, empty code `""`, or code with SQL text `' OR 1=1 --`. **When** user applies it. **Then** a safe "Invalid code" message; no server error; nothing is logged as an error. | Medium |

More cases to think about: code applied, then cart changed (item removed: is the code still valid for the new total?); two codes at once; code for another product; user logs out between apply and pay; payment fails after code is "used" (is the use refunded?).

Priority rule: **High** = money, security or the main flow; **Medium** = common edge cases; **Low** = rare or cosmetic.

### 6.4 Are your tests good tests?

A green test suite only helps if the tests can fail. Check your tests for these smells:

- [ ] No assertion, or only `toBeTruthy` / `toBeDefined` on a complex result
- [ ] Asserts implementation details (private state, call counts) instead of behaviour
- [ ] Snapshot-only tests for logic
- [ ] Real time (`setTimeout`, `sleep`, `Date.now()` without fake timers), real randomness, or real network
- [ ] Tests that depend on order or share mutable state
- [ ] Over-mocking: the thing under test is mocked
- [ ] `try/catch` that swallows a failing assertion
- [ ] Skipped or commented-out tests (`.skip`, `xit`, `@pytest.mark.skip`) without a reason
- [ ] Vague names (`works`, `test1`)
- [ ] One test that checks many behaviours

**Flaky tests.** Run the related test files 3 times. A test that changes result between runs is a bug in the test or in the code. Never just re-run until it is green.

**Mutation testing.** A mutation tool makes small changes to your code (for example `<` becomes `<=`). If no test fails after a change, your tests have a gap. For JS/TS use Stryker:

```bash
npm i -D @stryker-mutator/core
npx stryker run --mutate "src/features/billing/**/*.ts"
```

For Python use `mutmut`. Aim for 70%+ on business logic. Do not chase 100%.

---

## 7. Exploratory testing in 30 minutes

Exploratory testing = learn, design and run tests at the same time, with a goal. It finds bugs that scripted tests miss.

### 7.1 Charter template

> **Explore** `<area>` **with** `<resources: data, tools, roles, devices>` **to discover** `<risk or type of bug>`

Examples:
- Explore **the checkout discount field** with **expired, duplicate and malformed codes** to discover **wrong totals and server errors**.
- Explore **the profile page** with **a phone on slow 3G** to discover **missing loading and error states**.
- Explore **the invite flow** with **two users and two roles** to discover **permission leaks**.

### 7.2 Time-boxed routine

| Minutes | Step | What to do |
|---|---|---|
| 0-5 | **Tour** | Use the feature like a normal user. Note what is unclear or slow. Do not hunt bugs yet. |
| 5-20 | **Attack** | Use heuristics from section 2.4 and values from section 5. Try to break it: boundaries, interrupts, two tabs, wrong roles, bad network. Keep notes as you go. |
| 20-25 | **Notes** | Write what you tested, what you did not test, what felt risky, any questions. |
| 25-30 | **Bug reports** | Write each bug with the template in section 8. Add a screenshot or video. |

Tips:
- Set a timer. Stop when it rings. Start a new charter if needed.
- Open dev tools: Console (errors) and Network (failed calls, slow calls). A red error in the Console while "everything looks fine" is a bug.
- Test with a fresh account and with an old account.

---

## 8. Bug report template

A good report lets another person reproduce the bug in 2 minutes.

```markdown
**Title:** <short, specific: what breaks, where>
Example: Discount code applied twice when "Apply" is double-clicked

**Environment:** Browser/OS/device, app version or commit, environment (local/staging/prod), account/role

**Steps to reproduce:**
1. Go to ...
2. Click ...
3. Enter ...

**Expected:** What should happen

**Actual:** What happens instead (include exact error text)

**Severity:** S1 / S2 / S3 / S4
**Priority:** P1 / P2 / P3 (set by the product owner)

**Evidence:** Screenshot / video / console log / network request / log line

**Frequency:** Always / 3 of 5 tries / once / only on slow network
```

### 8.1 Severity vs priority

- **Severity** = how bad is the damage? (technical, set by QA / developer)
- **Priority** = how soon do we fix it? (business, set by the product owner)

They are different:
- Typo in the company name on the home page: low severity (S4), high priority (fix today).
- Crash in a rarely used admin report: high severity (S2), low priority (few users).

### 8.2 Severity definitions

| Level | Name | Meaning | Example |
|---|---|---|---|
| **S1** | Critical | Data loss, security hole, or crash in the main flow. No workaround. | User can read another user's orders. Checkout crashes. |
| **S2** | Major | A major function is broken and there is no workaround. | Cannot apply any discount code. |
| **S3** | Minor | A minor function is broken, or a workaround exists. | Filter fails, but search works. |
| **S4** | Cosmetic | Looks wrong, works right. | Misaligned icon, typo. |

---

## 9. Definition of Done

A feature is done only when **all** of these are true:

- [ ] `qa-check.ps1 -Mode full` passes (no FAIL)
- [ ] `/qa-review` verdict is not **Block**, and all S1 and S2 findings are fixed
- [ ] Every acceptance criterion is covered by a test (automated, or manual with a note)
- [ ] Every acceptance criterion is VERIFIED with evidence (a ticked box is not evidence)
- [ ] No flaky tests in the changed area
- [ ] Edge cases from section 5 were tried for each input
- [ ] Every create/edit/delete action was checked for data flow (list, detail, counts, after reload)
- [ ] Every positive and negative case in the checklist was tested (none left NOT RUN without a reason)
- [ ] No new WARN is ignored without a written reason
- [ ] No SKIP stage that you could fix by installing a tool
- [ ] The checklist in section 4 is done (or "N/A" with a reason)
- [ ] Another person reviewed the code and the tests
- [ ] The rollback is known (flag, revert, or migration down)
- [ ] Docs and changelog are updated

If one box is empty, the feature is not done. It is "almost done".

---

## 10. Daily workflow

Before every push:

1. **Write the feature and its tests together.** Cover the happy path, the errors and the boundaries.
2. **Run the quick gate** after each meaningful change:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\qa-check.ps1
   ```
   Fix every FAIL. Read every WARN.
3. **Run `/qa-review`** in Claude Code. Read the findings, fix S1 and S2, answer the questions for the author. Use `/qa-review --fix` to let it fix confirmed bugs: it adds a regression test for each fix and does not commit. It checks CRUD data flow and tests every case it lists (use `/qa-review --write-tests` to also turn every case into an automated test).
4. **Try it by hand for 10 minutes** with the cheat sheet (section 5). Use the exploratory routine (section 7) for bigger features.
5. **Run the full gate** before you open the PR or merge:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\qa-check.ps1 -Mode full -E2E
   ```
6. **Tick the checklist** (section 4) in the PR description. Ask another person to review.
7. **Push.** Watch logs and errors for the first 30 minutes after release.

Quick map:

| Step | Tool | Finds |
|---|---|---|
| 2 | `qa-check.ps1` | Mechanical bugs |
| 3 | `/qa-review` | Logic and requirement bugs |
| 4 | You, by hand | UX and "feels wrong" bugs |
| 5 | `qa-check.ps1 -Mode full -E2E` | Build, dependency and journey bugs |
| 6 | Checklist + human review | What everything else missed |
