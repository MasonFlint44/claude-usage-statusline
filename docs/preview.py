#!/usr/bin/env python3
"""Render the statusline once, with fixed inputs, and write it as SVG.

The README's preview is generated from the script itself so it cannot drift
from what the code draws. Development-only: needs python3, git and jq. Reset
times are set relative to the current clock, so the countdowns come out the
same on every run.

    docs/preview.py            # writes docs/preview.svg and docs/preview.txt
"""
import html, os, re, shutil, subprocess, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
SCRIPT = os.path.join(REPO, "statusline", "usage-statusline.sh")
COLS = 150
# 5-hour window hot enough to show its countdown, 7-day cool, the Fable week
# past the countdown threshold, and a little overage so the credits line shows.
INPUT = ('{"model":{"display_name":"Opus"},"effort":{"level":"high"},'
         '"context_window":{"used_percentage":42.6},'
         '"cost":{"total_cost_usd":3.72,"total_lines_added":118,"total_lines_removed":27},'
         '"rate_limits":{"five_hour":{"used_percentage":78,"resets_at":%d},'
         '"seven_day":{"used_percentage":41,"resets_at":%d}},'
         '"workspace":{"current_dir":"%s"}}')
# cache: <fable-percent> <spend-dollars> <fable-reset-epoch> <spend-limit-dollars>
CACHE = "74 12.50 {reset} 100\n"

def sh(*args, **kw):
    return subprocess.run(args, check=True, capture_output=True, text=True, **kw).stdout

def main():
    tmp = tempfile.mkdtemp()
    # A repo for the location row: on a feature branch, one commit ahead of
    # main, with uncommitted work.
    work = os.path.join(tmp, "claude-usage-statusline"); os.makedirs(work)
    env_git = {**os.environ, "GIT_AUTHOR_NAME": "p", "GIT_AUTHOR_EMAIL": "p@x", "GIT_COMMITTER_NAME": "p", "GIT_COMMITTER_EMAIL": "p@x"}
    g = lambda *a: sh("git", "-C", work, *a, env=env_git)
    g("init", "-q", "-b", "main")
    open(os.path.join(work, "README.md"), "w").write("hello\n" * 20)
    g("add", "."); g("commit", "-q", "-m", "init")
    g("checkout", "-q", "-b", "feature/preview")
    open(os.path.join(work, "notes.md"), "w").write("x\n" * 30)
    g("add", "."); g("commit", "-q", "-m", "notes")
    open(os.path.join(work, "README.md"), "w").write("hello\n" * 24 + "world\n" * 8)
    open(os.path.join(work, "scratch.txt"), "w").write("y\n" * 4)
    # A fresh cache and no credentials in the fake HOME: nothing is fetched.
    cache = os.path.join(tmp, ".claude", "cache", "statusline"); os.makedirs(cache)
    now = int(time.time())
    # The extra 30 s keeps a slow run from ticking a countdown down a minute.
    open(os.path.join(cache, "plan-usage"), "w").write(CACHE.format(reset=now + 2 * 86400 + 5 * 3600 + 30))
    env = {**os.environ, "HOME": tmp, "COLUMNS": str(COLS)}
    env.pop("CLAUDE_CONFIG_DIR", None)
    out = subprocess.run(["bash", SCRIPT], input=INPUT % (now + 100 * 60 + 30, now + 4 * 86400 + 30, work),
                         capture_output=True, text=True, env=env, check=True).stdout.rstrip("\n")
    shutil.rmtree(tmp)
    open(os.path.join(HERE, "preview.txt"), "w").write(re.sub(r"\x1b\[[0-9;]*m", "", out) + "\n")
    open(os.path.join(HERE, "preview.svg"), "w").write(to_svg(out))
    print(re.sub(r"\x1b\[[0-9;]*m", "", out))

FG, DIM_OPACITY, CW, LH, PAD = "#d4d4d4", 0.55, 8.4, 22, 14
# Bar cells are drawn as rectangles on the column grid rather than as glyphs:
# few monospace fonts carry the block characters, so a browser falls back to a
# font with other widths and the bars come out seamed, dithered and misaligned.
BAR_H, SHADE_OPACITY, TICK_W = 14, 0.22, 2

def cells(line):
    """ANSI (24-bit fg, dim, reset) -> [(char, fill, dim)], one per column."""
    fill, dim, out = FG, False, []
    for tok in re.split(r"(\x1b\[[0-9;]*m)", line):
        if tok.startswith("\x1b["):
            codes = tok[2:-1].split(";")
            if codes[:2] == ["38", "2"] and len(codes) == 5:
                fill = "#%02x%02x%02x" % tuple(int(c) for c in codes[2:5])
            elif codes == ["2"]:
                dim = True
            elif codes in (["0"], [""]):
                fill, dim = FG, False
        else:
            out.extend((ch, fill, dim) for ch in tok)
    return out

def to_svg(text):
    """Every text run is pinned to its column (x + textLength), so a fallback
    glyph cannot push the rest of the line off the grid."""
    rows = [cells(l) for l in text.split("\n")]
    width = max(len(r) for r in rows)
    w, h = round(width * CW + 2 * PAD), len(rows) * LH + 2 * PAD - 4
    body = []
    for i, row in enumerate(rows):
        base = PAD + LH * (i + 1) - 6
        top = base - BAR_H + 3
        col = 0
        while col < len(row):
            ch, fill, dim = row[col]
            x = PAD + col * CW
            op = ' opacity="%s"' % DIM_OPACITY if dim else ""
            if ch in "\u2588\u2591":
                # One rect per same-colored run: abutting translucent cells
                # would stripe where they overlap.
                end = col
                while end < len(row) and row[end] == row[col]:
                    end += 1
                if ch == "\u2591":
                    op = ' opacity="%s"' % SHADE_OPACITY
                body.append('<rect x="%.1f" y="%d" width="%.1f" height="%d" fill="%s"%s/>' % (x, top, (end - col) * CW, BAR_H, fill, op))
                col = end
                continue
            elif ch == "\u2502":
                body.append('<rect x="%.1f" y="%d" width="%d" height="%d" fill="%s"%s/>' % (x + (CW - TICK_W) / 2, top - 2, TICK_W, BAR_H + 4, fill, op))
            else:
                end = col
                while end < len(row) and row[end][1:] == (fill, dim) and row[end][0] not in "\u2588\u2591\u2502":
                    end += 1
                run = "".join(c[0] for c in row[col:end])
                if run.strip():
                    body.append('<text x="%.1f" y="%d" textLength="%.1f" lengthAdjust="spacingAndGlyphs" fill="%s"%s xml:space="preserve">%s</text>'
                                % (x, base, (end - col) * CW, fill, op, html.escape(run)))
                col = end
                continue
            col += 1
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" '
            'font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="14">\n'
            '<rect width="100%%" height="100%%" rx="8" fill="#1e1e1e"/>\n%s\n</svg>\n') % (w, h, w, h, "\n".join(body))

if __name__ == "__main__":
    main()
