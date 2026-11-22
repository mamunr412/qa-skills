# qa-skills

Think like a senior QA engineer: a Claude Code skill and a one-command quality gate that catch bugs before you push.

## What is inside

| Part | What it is | Link |
|---|---|---|
| `/qa-review` skill | Reviews a feature, module or project like a senior QA engineer and gives a verdict | [skills/qa-review](skills/qa-review/SKILL.md) |
| `qa-check.ps1` gate | One PowerShell command: format, lint, types, tests, secrets, build, audit | [qa-check.ps1](skills/qa-review/scripts/qa-check.ps1) |
| QA Playbook | The guide behind both: setup, mindset, checklists, edge cases, test design | [docs/QA-PLAYBOOK.md](docs/QA-PLAYBOOK.md) |

## Install

With the skills CLI:

```bash
npx skills add mamunr412/qa-skills --skill qa-review
```

Or copy it by hand. Clone this repo, then copy the whole `skills/qa-review/` folder:

```powershell
# This project only
New-Item -ItemType Directory -Force <your-project>\.claude\skills
Copy-Item -Recurse -Force .\skills\qa-review <your-project>\.claude\skills

# All projects
New-Item -ItemType Directory -Force "$env:USERPROFILE\.claude\skills"
Copy-Item -Recurse -Force .\skills\qa-review "$env:USERPROFILE\.claude\skills"
```

Restart Claude Code, then type `/qa-review`.

The skill ships its own copy of `qa-check.ps1`, so you do not need to copy the script. If you want to run the gate yourself, copy it into your project root.

## Usage

| Command | What it does |
|---|---|
| `/qa-review` | Reviews the changes on the current branch |
| `/qa-review src/features/billing` | Reviews that module and the code that uses it |
| `/qa-review 123` | Reviews pull request 123 (diff and description) |
| `/qa-review <issue-url>` | Reads the ticket and checks its acceptance criteria |
| `/qa-review --full` | Reviews the whole project or release, with the full gate |
| `/qa-review --write-tests` | Writes and runs automated tests for every case |
| `/qa-review --fix` | Fixes confirmed bugs, adds a regression test for each, never commits |

Run the gate on its own:

```powershell
# Quick check, 1-3 minutes
powershell -ExecutionPolicy Bypass -File .\qa-check.ps1

# Before a PR: coverage, build, audit, end-to-end tests
powershell -ExecutionPolicy Bypass -File .\qa-check.ps1 -Mode full -E2E
```

Results are written to `.qa/qa-report.md`. Add `.qa/` to your `.gitignore`.

## What /qa-review does

- Finds the scope: your branch diff, a path, a PR, a ticket, or a feature description.
- Treats acceptance criteria as claims. A ticked box is not proof, so each one is checked.
- Builds a risk map and spends most of the time on high-risk areas.
- Runs the `qa-check` gate and reads every failing log.
- Hunts bugs with proven heuristics: boundaries, bad input, state, timing, permissions.
- Checks CRUD data flow: do the list, the detail page and the counts update after create, edit and delete?
- Builds a full checklist of positive, negative and edge cases, tests every one, and marks it PASS, FAIL or NOT RUN.
- Reviews test quality: weak tests, flaky tests, and mutation testing.
- With `--fix`, fixes confirmed bugs with a regression test each. It never commits.
- Ends with a verdict: Ship, Ship with fixes, or Block.

## Tested on a sample app

The test app was a small Tasks app with 8 planted bugs: 6 code bugs, 1 weak test and 1 flaky test. Its own tests all passed.

| Run | Result |
|---|---|
| Read-only | Found 8 of 8 bugs, plus 3 extra real issues. Verdict: Block. 30 of 30 cases tested, 15 FAIL. |
| `--fix` | Fixed all 8 bugs with 22 regression tests. 32 of 32 tests passed, 5 runs in a row. Left 5 product decisions to the author. Nothing committed. |

Limit: the sample app had no UI, so the browser checks were not exercised.

## Requirements

- Claude Code, or another agent that supports skills.
- Windows PowerShell 5.1 or PowerShell 7 for the gate. PowerShell 7 is not yet tested.
- Optional: [gitleaks](https://github.com/gitleaks/gitleaks) for secret scanning, [Stryker](https://stryker-mutator.io/) for mutation testing.

## License

MIT. See [LICENSE](LICENSE).
