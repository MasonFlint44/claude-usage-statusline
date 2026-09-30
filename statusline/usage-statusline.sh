#!/usr/bin/env bash
input=$(cat)

# ANSI color codes
CLR_DIM='\033[2m'
CLR_RESET='\033[0m'

# Shared heat ramp (24-bit truecolor): muted green -> Claude gold -> Claude coral,
# as channel arrays plus the percentage each stop is anchored at. Both the effort
# level and the progress bars draw from this, so their colors line up.
# Anchored on Claude Code's own tokens: gold #fab219 (warning) + coral #ff5858 (error).
#
# Three stops, not five: the intermediate gold-green/orange the ramp used to carry
# explicitly are within ~16/255 of what a straight lerp between these produces, so
# they were paying no rent. Roughly: 0% green, 50% gold, 100% coral.
#
# The 5/95 anchors (rather than 0/100) inset the endpoints just enough that full
# coral means ">=95%" instead of "exactly 100%" -- the alarm saturates while you can
# still act on it. Clamping outside the anchors is continuous in color and only puts
# a corner in the rate of change, so the small flat zones cost nothing in smoothness.
RAMP_R=(107 250 255)   # #6bb85f  #fab219  #ff5858
RAMP_G=(184 178  88)
RAMP_B=( 95  25  88)
RAMP_AT=(  5  50  95)

# Map a 0-100 percentage to a continuously interpolated ramp color. Single source
# of truth for the bars, so they all read on the same scale.
# Pure bash integer math (no subshell) since this runs on every render.
ramp_color() {
    local p="${1:-0}"
    p="${p%%.*}"; [ -z "$p" ] && p=0
    (( p < 0 )) && p=0
    (( p > 100 )) && p=100

    local last=$(( ${#RAMP_AT[@]} - 1 ))
    local r g b
    if (( p <= RAMP_AT[0] )); then
        r=${RAMP_R[0]}; g=${RAMP_G[0]}; b=${RAMP_B[0]}
    elif (( p >= RAMP_AT[last] )); then
        r=${RAMP_R[last]}; g=${RAMP_G[last]}; b=${RAMP_B[last]}
    else
        # Find the segment containing p, then lerp each channel across it.
        local i=0
        while (( p > RAMP_AT[i+1] )); do i=$(( i + 1 )); done
        local span=$(( RAMP_AT[i+1] - RAMP_AT[i] ))
        local t=$(( p - RAMP_AT[i] ))
        r=$(( RAMP_R[i] + (RAMP_R[i+1] - RAMP_R[i]) * t / span ))
        g=$(( RAMP_G[i] + (RAMP_G[i+1] - RAMP_G[i]) * t / span ))
        b=$(( RAMP_B[i] + (RAMP_B[i+1] - RAMP_B[i]) * t / span ))
    fi
    # Emit the escape literally (\033, not a real ESC): the final render pipes the
    # whole line through `printf '%b'`, matching the CLR_*/RAMP_* constants above.
    printf '\\033[38;2;%d;%d;%dm' "$r" "$g" "$b"
}

# Map an effort level to its ramp color by sampling the ramp at evenly spaced
# points, so the five levels stay visually distinct and stay in sync with the bars
# automatically if the stops above ever change. Unknown -> dim.
effort_color() {
    case "$1" in
        low)    ramp_color   0 ;;
        medium) ramp_color  25 ;;
        high)   ramp_color  50 ;;
        xhigh)  ramp_color  75 ;;
        max)    ramp_color 100 ;;
        *)      printf '%s' "$CLR_DIM" ;;
    esac
}

# Build an ASCII progress bar with the percentage shown after the bar: bar <pct> <width>
# e.g. bar 42 10 -> █████░░░░░ 42%  (width = number of block characters)
# Fill color: continuous green -> gold -> coral ramp, see ramp_color().
bar() {
    local pct="${1:-0}"
    local width="${2:-10}"

    local pct_int
    pct_int=$(printf '%.0f' "$pct")

    # Filled and empty block counts based on full width
    local filled=$(printf '%.0f' "$(echo "$pct $width" | awk '{printf "%f", $1 * $2 / 100}')")
    [ "$filled" -gt "$width" ] && filled=$width
    local empty=$(( width - filled ))

    local fill_str empty_str color
    fill_str=''; for ((i=0; i<filled; i++)); do fill_str+='█'; done
    empty_str=''; for ((i=0; i<empty; i++)); do empty_str+='░'; done

    # Pick color from the shared ramp (matches the effort levels).
    local color
    color=$(ramp_color "$pct_int")

    # Colored filled blocks, then plain empty blocks, then space and percentage
    printf "${color}%s${CLR_RESET}%s %s%%" "$fill_str" "$empty_str" "$pct_int"
}

# Format a dollar amount compactly: <1000 -> $123, >=1000 -> $1.3k
fmt_money() {
    awk -v v="$1" 'BEGIN{
        if (v >= 1000) printf "$%.1fk", v/1000;
        else if (v >= 10) printf "$%.0f", v;
        else printf "$%.2f", v;
    }'
}

# --- Fable weekly limit + credit spend (cached, refreshed in background) ---
# This is the same data /usage renders: GET api.anthropic.com/api/oauth/usage with the
# CLI's own OAuth token. The response's limits[] carries a kind=weekly_scoped entry
# scoped to model "Fable" -- the included weekly allotment as a 0-100 percent -- and
# spend.used is real credit-overage money, nonzero only after that bar saturates.
# Undocumented internal endpoint, so every fetch/parse failure degrades to "keep the
# stale cache" and a valid-but-Fable-less response blanks it (segment hides itself).
CACHE_DIR="$HOME/.cache/claude-statusline"
CACHE_FILE="$CACHE_DIR/fable-usage"
LOCK_DIR="$CACHE_DIR/fable.lock"
REFRESH_INTERVAL=60
mkdir -p "$CACHE_DIR" 2>/dev/null

now=$(date +%s)

# Fetch the usage snapshot and cache it as
# "<fable-percent> <spend-dollars> <fable-reset-epoch> <spend-limit-dollars>".
# The spend fields are ACCOUNT-WIDE overage credits, not Fable-scoped.
# Runs detached.
refresh_fable() {
    local creds="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json"
    [ -r "$creds" ] || return
    local tok exp
    tok=$(jq -r '.claudeAiOauth.accessToken // empty' "$creds" 2>/dev/null)
    [ -z "$tok" ] && return
    # Expired token: skip rather than burn a 401. A running session rotates the
    # credentials file on its own; we serve the stale cache until it does.
    exp=$(jq -r '.claudeAiOauth.expiresAt // 0' "$creds" 2>/dev/null)
    exp="${exp%%.*}"
    [ "${exp:-0}" -gt "$(( now * 1000 ))" ] 2>/dev/null || return

    # The token travels in a curl config on stdin, not argv, so it never shows in ps.
    local resp
    resp=$(curl -s -m 5 -K - <<EOF
url = "https://api.anthropic.com/api/oauth/usage"
header = "Authorization: Bearer $tok"
header = "anthropic-beta: oauth-2025-04-20"
header = "Content-Type: application/json"
EOF
    ) || return

    local parsed
    parsed=$(printf '%s' "$resp" | jq -r '
        if (.limits | type) == "array" then
            (first(.limits[] | select(.kind == "weekly_scoped"
                and ((.scope.model.display_name // "") | ascii_downcase) == "fable")) // null) as $f
            | if $f == null then "none"
              else "\($f.percent) \((.spend.used.amount_minor // 0) / 100) \((($f.resets_at // "") | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | (fromdateiso8601? // 0))) \((.spend.limit.amount_minor // 0) / 100)" end
        else empty end' 2>/dev/null)
    case "$parsed" in
        "")     return ;;                                          # bad fetch: keep stale cache
        none)   : > "$CACHE_FILE.tmp" 2>/dev/null ;;               # no Fable window: blank it
        *)      printf '%s\n' "$parsed" > "$CACHE_FILE.tmp" 2>/dev/null ;;
    esac && mv "$CACHE_FILE.tmp" "$CACHE_FILE" 2>/dev/null
}

# Decide whether to trigger a background refresh.
cache_age=$(( now - $(stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0) ))
if [ ! -f "$CACHE_FILE" ] || [ "$cache_age" -ge "$REFRESH_INTERVAL" ]; then
    # Clear a stale lock (crashed/killed refresher) so refreshes can't wedge permanently.
    if [ -d "$LOCK_DIR" ]; then
        lock_age=$(( now - $(stat -c %Y "$LOCK_DIR" 2>/dev/null || echo "$now") ))
        [ "$lock_age" -gt 120 ] && rmdir "$LOCK_DIR" 2>/dev/null
    fi
    # mkdir is atomic: only one refresher runs at a time.
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        ( refresh_fable; rmdir "$LOCK_DIR" 2>/dev/null ) >/dev/null 2>&1 &
        disown 2>/dev/null
    fi
fi

fable_pct=""; fable_spend=""; fable_reset=""; spend_limit=""
[ -f "$CACHE_FILE" ] && read -r fable_pct fable_spend fable_reset spend_limit < "$CACHE_FILE" 2>/dev/null

# Model info
model=$(echo "$input" | jq -r '.model.display_name // empty')

# Reasoning effort level (low | medium | high | xhigh | max)
effort=$(echo "$input" | jq -r '.effort.level // empty')

# Context usage
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')

# Session cost (real-time, already in the input)
session_cost=$(echo "$input" | jq -r '.cost.total_cost_usd // empty')

# Rate limits (percentages + reset instants, epoch seconds)
five_hr=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
seven_day=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
five_hr_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
seven_day_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')

# Location + session churn
cur_dir=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // empty')
lines_added=$(echo "$input" | jq -r '.cost.total_lines_added // 0')
lines_removed=$(echo "$input" | jq -r '.cost.total_lines_removed // 0')

# --- Responsive bar widths: bars fill the terminal width ---
# The statusline runs as a piped command (no controlling TTY), but Claude Code
# exports the terminal width as $COLUMNS. Fall back to tput, then to 80.
cols="${COLUMNS:-0}"
[ "$cols" -gt 0 ] 2>/dev/null || cols=$(tput cols 2>/dev/null || echo 80)

# COLUMNS is the raw terminal width, but the fullscreen TUI doesn't give the
# statusline all of it: the frame (border + padding) eats ~4 columns. Reserve
# those plus one spare so the right edge never truncates.
RESERVE=5
avail=$(( cols - RESERVE ))

# All bars render at ONE shared width so they read on the same visual scale:
# 16 blocks by default, stretched or squeezed together so the line fills the
# terminal. The floor is 10 blocks -- one block per 10%, the coarsest a bar
# still carries real information; rather than squeeze below it we wrap to two
# rows (and only a terminal too narrow even for that renders floor-width bars
# that overflow).
BAR_NOM=16; BAR_MIN=10

# Precompute the variable-length text pieces so we can measure the fixed
# "chrome" (everything that isn't bar blocks) exactly.
[ -n "$session_cost" ] && session_money=$(fmt_money "$session_cost") || session_money=""
have_fable=0; fab_i=""
if [ -n "$fable_pct" ]; then
    have_fable=1
    fab_i=$(printf '%.0f' "$fable_pct")
fi
ctx_i=$( [ -n "$used_pct" ]   && printf '%.0f' "$used_pct"   || echo "" )
h5_i=$(  [ -n "$five_hr" ]    && printf '%.0f' "$five_hr"    || echo "" )
d7_i=$(  [ -n "$seven_day" ]  && printf '%.0f' "$seven_day"  || echo "" )

have_ctx=0; have_5h=0; have_7d=0
[ -n "$used_pct" ]  && have_ctx=1
[ -n "$five_hr" ]   && have_5h=1
[ -n "$seven_day" ] && have_7d=1

# --- Reset countdowns, shown only once a bar runs HOT (>= threshold) ---
# Below the threshold the percentage is the whole story; near the limit "when
# does it reset" becomes the question worth answering, so the countdown appears
# (dim, in parens) beside the hot bar's percentage -- and the line changing
# shape is itself the early warning. ASCII only, so width math stays exact.
HOT_PCT=70
fmt_countdown() {   # $1 = reset epoch -> e.g. 3d2h / 1h40m / 25m / <1m
    local r="${1:-0}" d
    r="${r%%.*}"
    [ "$r" -gt "$now" ] 2>/dev/null || return
    d=$(( r - now ))
    if   (( d >= 86400 )); then printf '%dd%dh' $(( d / 86400 )) $(( d % 86400 / 3600 ))
    elif (( d >= 3600 ));  then printf '%dh%dm' $(( d / 3600 ))  $(( d % 3600 / 60 ))
    elif (( d >= 60 ));    then printf '%dm' $(( d / 60 ))
    else printf '<1m'; fi
}
h5_cd=""; d7_cd=""; fab_cd=""
[ "$have_5h" = 1 ]    && [ "${h5_i:-0}" -ge "$HOT_PCT" ]  && h5_cd=$(fmt_countdown "$five_hr_reset")
[ "$have_7d" = 1 ]    && [ "${d7_i:-0}" -ge "$HOT_PCT" ]  && d7_cd=$(fmt_countdown "$seven_day_reset")
[ "$have_fable" = 1 ] && [ "${fab_i:-0}" -ge "$HOT_PCT" ] && fab_cd=$(fmt_countdown "$fable_reset")

# --- Per-piece visible "chrome" widths (everything that isn't bar blocks) ---
# Only "·" is multibyte; " · " is counted as the constant 3, the rest is ASCII,
# so ${#...} is a correct column count regardless of locale.
model_w=0
if [ -n "$model" ]; then
    model_w=${#model}
    [ -n "$effort" ] && model_w=$(( model_w + 3 + ${#effort} ))       # " · <effort>"
fi
ctx_chrome=0
if [ "$have_ctx" = 1 ]; then
    ctx_chrome=$(( 4 + 1 + ${#ctx_i} + 1 ))                           # "ctx:" + " NN%"
    [ -n "$session_money" ] && ctx_chrome=$(( ctx_chrome + 1 + ${#session_money} ))
fi
h5_chrome=0; [ "$have_5h" = 1 ] && h5_chrome=$(( 3 + 1 + ${#h5_i} + 1 ))   # "5h:" + " NN%"
d7_chrome=0; [ "$have_7d" = 1 ] && d7_chrome=$(( 3 + 1 + ${#d7_i} + 1 ))   # "7d:" + " NN%"
[ -n "$h5_cd" ] && h5_chrome=$(( h5_chrome + 3 + ${#h5_cd} ))              # " (X)"
[ -n "$d7_cd" ] && d7_chrome=$(( d7_chrome + 3 + ${#d7_cd} ))
fab_chrome=0
if [ "$have_fable" = 1 ]; then
    fab_chrome=$(( 6 + 1 + ${#fab_i} + 1 ))                           # "Fable:" + " NN%"
    [ -n "$fab_cd" ] && fab_chrome=$(( fab_chrome + 3 + ${#fab_cd} ))
fi
SEP=3   # width of " | "

# Rate segment: 5h and 7d share one " | "-delimited segment, with a space between.
rate_chrome=0; have_rate=0
if [ "$have_5h" = 1 ] || [ "$have_7d" = 1 ]; then
    have_rate=1
    [ "$have_5h" = 1 ] && rate_chrome=$(( rate_chrome + h5_chrome ))
    if [ "$have_7d" = 1 ]; then
        [ "$have_5h" = 1 ] && rate_chrome=$(( rate_chrome + 1 ))      # space between 5h and 7d
        rate_chrome=$(( rate_chrome + d7_chrome ))
    fi
fi

# Shared bar width for a row: split the column budget evenly across its bars,
# clamped to the floor. The division remainder (at most nbars-1 columns) is left
# unfilled rather than making one bar wider than its siblings.
# Args: <budget> <nbars>. Echoes the width.
equal_width() {
    local budget=$1 n=$2 w
    w=$(( budget / n ))
    (( w < BAR_MIN )) && w=$BAR_MIN
    echo "$w"
}

# --- Segment builders (return the colored text for one segment) ---
build_model() {
    [ -z "$model" ] && return
    local s="$model"
    [ -n "$effort" ] && s="$s ${CLR_DIM}·${CLR_RESET} $(effort_color "$effort")$effort${CLR_RESET}"
    printf '%s' "$s"
}
build_ctx() {   # $1 = bar width
    [ "$have_ctx" = 1 ] || return
    local s="ctx:$(bar "$used_pct" "$1")"
    [ -n "$session_money" ] && s="$s ${CLR_DIM}${session_money}${CLR_RESET}"
    printf '%s' "$s"
}
build_rate() {  # $1 = 5h width, $2 = 7d width
    local s=""
    if [ "$have_5h" = 1 ]; then
        s="5h:$(bar "$five_hr" "$1")"
        [ -n "$h5_cd" ] && s="$s ${CLR_DIM}(${h5_cd})${CLR_RESET}"
    fi
    if [ "$have_7d" = 1 ]; then
        s="$s 7d:$(bar "$seven_day" "$2")"
        [ -n "$d7_cd" ] && s="$s ${CLR_DIM}(${d7_cd})${CLR_RESET}"
    fi
    printf '%s' "${s# }"
}
build_fable() { # $1 = bar width
    [ "$have_fable" = 1 ] || return
    local s="Fable:$(bar "$fable_pct" "$1")"
    [ -n "$fab_cd" ] && s="$s ${CLR_DIM}(${fab_cd})${CLR_RESET}"
    printf '%s' "$s"
}
# Overage usage credits (account-wide, not Fable-scoped) as a whole line of
# their own, below the bars. Self-hiding: spending past the plan limits is
# rare enough that the line materializing IS the alert; the rest of the time
# the layout doesn't pay for it.
build_credits() {
    [ -n "$fable_spend" ] || return
    awk -v v="$fable_spend" 'BEGIN{exit !(v > 0)}' || return
    local pct=0
    [ -n "$spend_limit" ] && pct=$(awk -v u="$fable_spend" -v l="$spend_limit" \
        'BEGIN{printf "%d", (l > 0) ? u * 100 / l : 0}')
    local s="credits:$(bar "$pct" "$BAR_MIN")"
    s="$s ${CLR_DIM}$(fmt_money "$fable_spend")"
    [ -n "$spend_limit" ] && s="$s/$(fmt_money "$spend_limit")"
    printf '%s' "$s${CLR_RESET}"
}
# Render a "+A/-R" pair with zero sides suppressed (nothing at all when both
# are zero). $1=added $2=removed $3=style: "hot" (green/coral, the actionable
# pair) or "dim" (ambient context).
fmt_pair() {
    local a="${1:-0}" r="${2:-0}" style="$3" out=""
    [ "$a" -gt 0 ] 2>/dev/null || a=0
    [ "$r" -gt 0 ] 2>/dev/null || r=0
    (( a == 0 && r == 0 )) && return
    local pc mc
    if [ "$style" = hot ]; then pc="$(ramp_color 0)" mc="$(ramp_color 100)"; else pc="$CLR_DIM" mc="$CLR_DIM"; fi
    (( a > 0 )) && out="${pc}+${a}${CLR_RESET}"
    if (( r > 0 )); then
        [ -n "$out" ] && out="$out${CLR_DIM}/${CLR_RESET}"
        out="$out${mc}-${r}${CLR_RESET}"
    fi
    printf '%s' "$out"
}

# Parse `git diff --shortstat` on stdin -> "added removed" (0 0 when empty).
parse_shortstat() {
    awk '{for(i=1;i<=NF;i++){if($(i+1)~/insertion/)a=$i; if($(i+1)~/deletion/)d=$i}} END{printf "%d %d", a, d}'
}

# Location line grammar: path, branch, then facts ordered now -> ambient:
#   ~/git/x ⎇ branch pending +A/-R ↑a↓b · vs <default> +A/-R · session +A/-R
# Every group is self-hiding (pending only when dirty, arrows only with a
# nonzero count against upstream, vs-<default> only off the default branch,
# session only with churn), so the quiet state collapses to "path ⎇ branch".
# "pending" folds untracked-file lines (gitignore respected) into added; its
# presence IS the dirty flag. "behind" is as of the last fetch -- we never
# fetch here. Not width-managed: the TUI truncates rows on its own.
build_locline() {
    local dir="${cur_dir:-$PWD}"
    # ~-shorten; past 35 chars squeeze middle components fish-style (~/g/mowmap)
    # so a deep cwd can't push the interesting right side of the line off-screen.
    local disp="${dir/#$HOME/\~}"
    if [ ${#disp} -gt 35 ]; then
        disp=$(awk -v p="$disp" 'BEGIN{n=split(p,a,"/"); o=a[1]; for(i=2;i<n;i++) o=o"/"substr(a[i],1,1); print o"/"a[n]}')
    fi
    local s="${CLR_DIM}${disp}${CLR_RESET}"

    local branch shown a r pair
    branch=$(git -C "$dir" branch --show-current 2>/dev/null)
    [ -z "$branch" ] && branch=$(git -C "$dir" rev-parse --short HEAD 2>/dev/null)
    if [ -n "$branch" ]; then
        # Cap the shown name so a long branch can't evict the groups after it.
        shown="$branch"
        [ ${#shown} -gt 26 ] && shown="${shown:0:24}.."
        # Remote repo name, dim, only when it differs from the repo root's
        # dirname (~/git/dotclaude is dotclaude; ~/git/mowmap is just mowmap).
        local top repo
        top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)
        repo=$(git -C "$dir" remote get-url origin 2>/dev/null)
        repo=${repo##*/}; repo=${repo%.git}
        [ -n "$repo" ] && [ "$repo" != "${top##*/}" ] && s="$s ${CLR_DIM}(${repo})${CLR_RESET}"

        # Two spaces after ⎇ — the glyph's overhang visually eats one.
        s="$s ⎇  ${shown}"

        # pending: uncommitted lines vs HEAD + lines in untracked files
        read -r a r <<< "$(git -C "$dir" diff --shortstat HEAD 2>/dev/null | parse_shortstat)"
        local u
        # ls-files emits repo-relative paths, so cat must run from the repo too.
        u=$( (cd "$dir" 2>/dev/null && git ls-files --others --exclude-standard -z | xargs -0 -r cat 2>/dev/null) | wc -l )
        pair=$(fmt_pair $(( a + u )) "$r" hot)
        local cluster=""
        [ -n "$pair" ] && cluster="${CLR_DIM}pending${CLR_RESET} $pair"

        # ahead/behind upstream
        local behind ahead arrows=""
        read -r behind ahead <<< "$(git -C "$dir" rev-list --left-right --count '@{upstream}...HEAD' 2>/dev/null)"
        [ "${ahead:-0}" -gt 0 ] 2>/dev/null && arrows="↑$ahead"
        [ "${behind:-0}" -gt 0 ] 2>/dev/null && arrows="$arrows↓$behind"
        [ -n "$arrows" ] && cluster="${cluster:+$cluster }$arrows"

        # one separator for the whole working-state cluster, matching the
        # dim · that introduces the vs/session groups
        [ -n "$cluster" ] && s="$s ${CLR_DIM}·${CLR_RESET} $cluster"

        # vs default branch (origin/HEAD, falling back to main/master), hidden on it
        local def
        def=$(git -C "$dir" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)
        def=${def#origin/}
        if [ -z "$def" ]; then
            if git -C "$dir" show-ref --verify -q refs/heads/main; then def=main
            elif git -C "$dir" show-ref --verify -q refs/heads/master; then def=master; fi
        fi
        if [ -n "$def" ] && [ "$branch" != "$def" ]; then
            read -r a r <<< "$(git -C "$dir" diff --shortstat "$def...HEAD" 2>/dev/null | parse_shortstat)"
            pair=$(fmt_pair "$a" "$r" dim)
            [ -n "$pair" ] && s="$s ${CLR_DIM}· vs ${def}${CLR_RESET} $pair"
        fi
    fi

    pair=$(fmt_pair "$lines_added" "$lines_removed" dim)
    [ -n "$pair" ] && s="$s ${CLR_DIM}· session${CLR_RESET} $pair"
    printf '%s' "$s"
}
join_parts() {  # join non-empty args with " | "
    local out="" p
    for p in "$@"; do [ -z "$p" ] && continue; [ -n "$out" ] && out="$out | "; out="$out$p"; done
    printf '%s' "$out"
}

# --- One line, or two? Split only when a single row can't fit even with every
#     bar at its floor width. ---
nparts=0
[ -n "$model" ]        && nparts=$(( nparts + 1 ))
[ "$have_ctx" = 1 ]    && nparts=$(( nparts + 1 ))
[ "$have_rate" = 1 ]   && nparts=$(( nparts + 1 ))
[ "$have_fable" = 1 ]  && nparts=$(( nparts + 1 ))
one_fixed=$(( model_w + ctx_chrome + rate_chrome + fab_chrome ))
[ "$nparts" -gt 1 ] && one_fixed=$(( one_fixed + (nparts - 1) * SEP ))
nbars=$(( have_ctx + have_5h + have_7d + have_fable ))
min_bars=$(( nbars * BAR_MIN ))

BAR_W=$BAR_NOM

if [ $(( one_fixed + min_bars )) -le "$avail" ]; then
    # ---------- ONE LINE: split the row's budget evenly across all bars ----------
    [ "$nbars" -gt 0 ] && BAR_W=$(equal_width $(( avail - one_fixed )) "$nbars")
    out=$(join_parts "$(build_model)" "$(build_ctx "$BAR_W")" "$(build_rate "$BAR_W" "$BAR_W")" "$(build_fable "$BAR_W")")
else
    # ---------- TWO LINES: identity+context on row 1, limits+Fable on row 2 ----------
    # Each row could afford a different width; the tighter row sets the shared
    # width so bars still match across rows (the roomier row runs short).
    l1_nparts=0; [ -n "$model" ] && l1_nparts=$(( l1_nparts + 1 )); [ "$have_ctx" = 1 ] && l1_nparts=$(( l1_nparts + 1 ))
    l1_fixed=$(( model_w + ctx_chrome )); [ "$l1_nparts" -gt 1 ] && l1_fixed=$(( l1_fixed + SEP ))

    l2_nparts=0; [ "$have_rate" = 1 ] && l2_nparts=$(( l2_nparts + 1 )); [ "$have_fable" = 1 ] && l2_nparts=$(( l2_nparts + 1 ))
    l2_fixed=$(( rate_chrome + fab_chrome )); [ "$l2_nparts" -gt 1 ] && l2_fixed=$(( l2_fixed + SEP ))
    l2_nbars=$(( have_5h + have_7d + have_fable ))

    w1=""; w2=""
    [ "$have_ctx" = 1 ]   && w1=$(equal_width $(( avail - l1_fixed )) 1)
    [ "$l2_nbars" -gt 0 ] && w2=$(equal_width $(( avail - l2_fixed )) "$l2_nbars")
    if [ -n "$w1" ] && [ -n "$w2" ]; then
        BAR_W=$(( w1 < w2 ? w1 : w2 ))
    elif [ -n "$w1" ]; then BAR_W=$w1
    elif [ -n "$w2" ]; then BAR_W=$w2
    fi

    line1=$(join_parts "$(build_model)" "$(build_ctx "$BAR_W")")
    line2=$(join_parts "$(build_rate "$BAR_W" "$BAR_W")" "$(build_fable "$BAR_W")")

    out="$line1"
    if [ -n "$line2" ]; then [ -n "$out" ] && out="$out"$'\n'"$line2" || out="$line2"; fi
fi

# Location + churn always get their own final row.
credits_line=$(build_credits)
[ -n "$credits_line" ] && out="$out"$'\n'"$credits_line"

loc_line=$(build_locline)
[ -n "$loc_line" ] && out="$out"$'\n'"$loc_line"

printf '%b' "$out"
