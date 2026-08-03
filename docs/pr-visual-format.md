# PR visual format

This page is the tracked default the generated PR-description contract points at.
`bin/fm-pr-contract-lib.sh` owns that contract text and resolves the pointer at generation time: a captain-private `${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/pr-visual-format.md` wins when it exists on disk, otherwise the brief cites this file.
Because this copy ships with the repository, a crewmate in any checkout can always open the path its brief names.
A local override is for a fleet that wants house rules beyond the ones below; it replaces this page wholly rather than merging with it.

Everything here is written for the person reading the PR, not for the person who wrote it.
A reviewer arrives knowing nothing about the task and should leave knowing what changed, why, and what evidence exists.

## Body structure

Write the body in this order, and nothing else.

1. A purpose-first opening line naming the change's role.
   When the change belongs to an epic or an incident, that role comes first: what the epic or incident is, then where this change sits inside it.
2. A `## Changes` section of terse reviewer-facing bullets.
   One bullet per reviewer-visible behavior change, phrased as the new behavior rather than as a narrative of how it was reached.
3. Visual evidence appropriate to the change type, per the recipes below.
4. A one-line statement of known limitations.
   Write `None.` when there are none rather than dropping the line.
5. A one-line statement of test evidence naming what was run and what it proved.

Delete any Intent, Risk Assessment, or Pipeline sections a tool generated.
They describe the machinery that produced the change, not the change.

## Evidence recipes by change type

**Backend, infrastructure, and data flow.**
Embed a mermaid diagram of the flow the change alters.
Show the path after the change; when the shape itself is what changed, show both paths and label which is which.
Keep it to the nodes a reviewer must hold in mind, not the whole system.

**Bug fixes.**
Embed labeled Before and After evidence of the same reproduction.
Before shows the failure, After shows the same steps passing.
Command output, log excerpts, and screenshots all qualify; the labels and the shared reproduction are what make it evidence rather than decoration.

**Frontend and any user-visible surface.**
Embed screenshots of the affected states.
Cover the states the change touches, including empty, loading, and error states when they moved.
For a visual regression, use the same labeled Before and After pairing as a bug fix.
Capture at a realistic viewport with realistic content.

**Pure refactors with no behavior change.**
Say so explicitly in the opening line and carry the test evidence that proves it.
No diagram or screenshot is required when nothing observable moved.

## Banned in every PR body

- First-person implementation diaries.
- Fix-round archaeology and restated review-finding histories.
- Machine-generated Intent and Risk sections.
- Individual teammate names.
- Em-dashes.
- Ticket and issue-key citations.

The ticket ban covers all committed content, documentation prose and code comments alike; the key belongs in the PR title only.
Comments must be terse and self-contained, carrying every fact a reader needs rather than leaning on a ticket for context.
The single exception is an explicit marker pointing at tracked future work, formulated exactly as `TODO(ADC-123)`.

## Title

The title carries the ticket key and follows the repository's own commit-subject convention.
Verify the title and the body structure together in the same check, never one without the other.
