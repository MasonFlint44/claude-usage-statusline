# Plan 01 — Plan-limit fitting

Status: proposed. Runs after `claude-budget-statusline` Plan 01 has shipped
and its collector has gathered about a month of data on the home machine.

This repo becomes the plan-user sibling of `claude-budget-statusline`: the
same renderer and compaction machinery, with the day and month spend bars
replaced by the 5-hour, 7-day and Fable windows, plus a fitter that learns
how those windows actually charge for each kind of token.

## Naming

The working name is `claude-plan-statusline` (plugin `plan-statusline`,
skills `/plan-statusline:install` and so on). One problem with it: "plan" is
already a Claude Code word (plan mode, `/plan`, the Plan agent), so
`/plan-statusline:doctor` reads like a plan-mode command and skill-trigger
tests will have to fight that. Alternatives, in rough order of preference:

- `claude-quota-statusline` / `quota-statusline`: budget is dollars, quota is
  an allowance; reads cleanly next to the sibling.
- `claude-limits-statusline`: literal, matches the JSON field name
  `rate_limits`.
- `claude-window-statusline`: after the 5h and 7d windows; less obvious.
- `claude-meter-statusline`: neutral, but says nothing about plans.

Renaming is one `mv` and a `sed` until the remote exists.

## What is copied from the budget plugin

After its Plan 00 and Plan 01 ship, copy verbatim:

- `statusline/budget_statusline/` minus `usage.py`'s spend parsing, renamed
  to the package name here; `layout.py`, `display.py`, `calendar.py`,
  `repo.py`, `input.py`, `doctor.py` come across unchanged.
- `statusline/budget_statusline/compact/` in full, `compact-hook.sh`,
  `hooks/hooks.json`, `config/compact.conf`, the compaction tests and
  fixtures, the `compact-point` and `recalibrate` skills.
- The test harness: bats layout, fake `curl`, libfaketime rules, the skill
  runner and trigger scorer, CI workflow, `docs/preview.py`.

Then port `statusline/plan-statusline.sh` (the home script, copied here as
of 2026-09-07) onto that renderer: the 5h, 7d and Fable bars with their
reset countdowns, the credits line, and the location row, which the budget
renderer already draws. The home script's width reserve, bar floor and
wrap rules are documented in its header and must survive the port; its
rendered lines become goldens first.

Copying rather than sharing is a deliberate choice so each plugin installs
self-contained from the marketplace. Keep the `compact/` package byte-identical
between the two repos and sync it with a script, the way `work-export.sh`
does in dotclaude; if the copies start to diverge, that is the moment to
extract a shared package.

## The problem the fitter solves

On a subscription there is no bill. The 5-hour and 7-day windows (and the
Fable window, which is its own pool) report a percentage of an undisclosed
budget, and Anthropic does not publish how each token type counts toward it.
The compaction formula only needs two ratios, cache-read to cache-write and
output to cache-write, but the one bit that matters most is whether cache
reads count at roughly a tenth or at roughly full weight, because that alone
moves the compaction point by a factor of three. On the author's account
cache reads are about 97% of all tokens by count.

The fit also produces something worth having on its own: an empirical
version of Anthropic's usage formula, per model, per window, with error bars.

## Data

All of it is already collected by the compaction collector, plus one table
this plan fills:

- `calls`: per API call, per model, the five token types (input, cache read,
  cache write 5m, cache write 1h, output including thinking), web search and
  fetch request counts, `speed`, and whether it was a subagent call.
- `usage_samples`: the 5h and 7d `used_percentage` and `resets_at` from the
  statusline JSON on every render (the budget collector already writes these
  when present), plus the Fable window and the overage and extra-usage flags
  from the oauth usage endpoint on its 60-second refresh.
- Per-turn counts, for the intercept that absorbs Claude Code's own Haiku
  side calls (titles, recaps, classifiers), which never appear as transcript
  lines but do consume usage.

Every session's hooks write to the same store, so concurrent local sessions
are summed rather than confounded. Cloud sessions and the claude.ai apps on
the same account draw from the same windows and are invisible here; the
estimator is built to tolerate that.

## Estimator

**Intervals.** Between consecutive usage samples, form one observation per
window: the change in percentage, and the sum over all local sessions of
each regressor in that interval. Drop intervals where the window reset (the
percentage fell, or `resets_at` changed), where the window sat at its cap,
or where overage was active. Merge consecutive intervals until the
percentage moved at least two points, so rounding does not dominate.

**Regressors, per window and per model.** Input, cache read, cache write 5m,
cache write 1h, output, web search requests, web fetch requests, a fast-mode
copy of each token type when `speed` is fast, and the turn count. Raw input
tokens are nearly absent in Claude Code traffic and that coefficient is
unidentifiable; keep it but expect a wide interval.

**Fit.** Non-negative least squares with a ridge prior pulling each
coefficient toward the published price ratio for its type and model, so the
estimate is sane before there is data and the data dominates once there is.
Exponential forgetting with a half-life of about a month. Because unlogged
external usage can only push the percentage up, fit the lower envelope: a
quantile regression at a low quantile (start at the 20th) rather than the
mean. Intervals with zero local calls and a positive rise measure external
usage directly and are reported separately.

**Per window.** The 5-hour window is fixed-start and is fitted directly. The
7-day window is rolling: its change is new usage minus usage that aged out,
and the aged-out term is known from the store once it holds seven days, so
the 7-day fit includes it and becomes an independent estimate of the same
ratios. If the two windows' ratios disagree beyond their intervals, the
windows are weighted differently and the compaction formula uses whichever
window is nearer its cap. The Fable window is fitted on its own.

**Uncertainty.** Bootstrap over intervals for each coefficient and for the
two ratios the formula consumes. The interval decides when to prefer the
fitted ratio over the price prior, whether the two windows differ, whether
models are weighted differently, and whether any time-of-day effect is real.

**Change detection.** A running count of same-signed residuals; a run of ten
is a one-in-five-hundred event and flags a metering change, at which point
the forgetting is shortened. A new model id gets new coefficients at its
price prior; nothing else resets.

**Regimes for the compaction formula.** Plan account with a confident fit:
the fitted ratios replace `w_read / w_write` and `w_out / w_write`. Plan
account without one: the price ratios. Overage active: dollar prices and the
5-minute TTL's `w_write` and `miss_rate`, since the harness drops the TTL and
the account is billed at API rates.

## Experiments

| Id | Question | Method | Feeds |
|---|---|---|---|
| F1 | Identifiability pilot | Fit on the first two weeks of collected data; report intervals per coefficient. | whether the regressor set needs pruning; the prior strength |
| F2 | Percentage granularity | Histogram of `used_percentage` steps in the samples; how often a render sees a change. | the merge threshold |
| F3 | Reset behaviour | Watch `resets_at` and the percentage across several 5-hour resets and one 7-day week. | the interval exclusion rules |
| F4 | Does the JSON's `rate_limits` update per render or per fetch? | Compare consecutive renders' values against the endpoint's. | sample cadence |
| F5 | External usage share | Intervals with no local calls: how much of the budget they consume. | whether the lower-envelope quantile is enough |
| F6 | Time of day | Hour-of-day buckets as regressors; bootstrap says whether they differ. | drop or keep the buckets |
| F7 | Per-model weighting | Sessions on Sonnet, Opus and Fable in the same window; are the fitted multipliers proportional to price. | the per-model structure |
| F8 | Overage transition | What the endpoint reports and what the TTL does at the moment a window caps. | the regime switch |

F1, F2, F4, F5 and F7 are offline queries once a month of data exists. F3
and F8 are waits. F6 runs whenever there is enough data and ships nothing
unless it finds something.

## Presentation

The home script already draws the three window bars with reset countdowns.
Additions worth considering, each behind a display name:

- A projected time-to-cap on each window from the recent weighted burn rate
  (`5h: ██████░░ 74% · 1h20m left at this pace`), which is the first thing
  the fitted weights make possible.
- The compaction tick and cue, from the copied machinery, now using the
  fitted ratios.
- A `credits:` line while overage spend is positive, as today.
- The report skill shows the fitted formula: coefficients, intervals, tier,
  sample count, external-usage share, last change flag.

## Tests

Everything from the budget plugin's compaction tests, plus:

- The estimator on synthetic data with known weights: recovers them within
  the bootstrap interval at 50, 200 and 1000 intervals; with 20% of
  intervals contaminated by external usage; with a metering change halfway
  through (the run detector fires within 15 intervals); with a window
  reset and a cap in the middle.
- The 7-day aged-out term against a hand-computed rolling window.
- Interval construction from a recorded sample stream with rounding.
- Regime selection: fitted, prior, overage, each with the expected weights
  reaching `formula.py`.
- Render goldens for the window bars, the projection, the cue, at 60 and
  120 columns.
- Skill runs and trigger scoring for the renamed skills, with the plan-mode
  near-misses if the working name stays.

## Skills and docs

`install`, `doctor`, `display`, `compact-point`, `recalibrate` copied and
renamed; a new `limits` (or `quota`) skill that explains the fitted formula
and the projections. README written fresh for plan users, with the same
privacy note and a section on what the fitter can and cannot know.

## Open questions

- Whether the two repos should share a package after all. Decide after the
  first sync; the copy script makes the drift visible.
- Whether to keep the bash home script alive during the port or cut over in
  one release. The goldens make a cut-over safe; do that.
- The default quantile for the lower-envelope fit, and whether to switch to
  a plain fit when F5 shows external usage is negligible.
