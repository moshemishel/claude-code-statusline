#!/bin/zsh

BRANCH=$(git branch --show-current 2>/dev/null || echo "n/a")
DATA=$(cat)

DIR=$(echo "$DATA" | jq -r '.workspace.current_dir | split("/") | last')
MODEL=$(echo "$DATA" | jq -r '.model.display_name' | sed 's/ ([^)]*)//')
DUR=$(echo "$DATA" | jq -r '((.cost.total_duration_ms // 0) / 60000 | floor)')
CTX=$(echo "$DATA" | jq -r '(.context_window.used_percentage // 0)')

# ── Persist rate_limits from Claude response JSON (updated every reply) ──
INLINE_CACHE="/tmp/.claude-statusline-usage-inline-${PPID}"
RL_5H=$(echo "$DATA" | jq -r '.rate_limits.five_hour.used_percentage // empty' 2>/dev/null)
RL_7D=$(echo "$DATA" | jq -r '.rate_limits.seven_day.used_percentage // empty' 2>/dev/null)
RL_5H_RESET=$(echo "$DATA" | jq -r '.rate_limits.five_hour.resets_at // empty' 2>/dev/null)
if [[ -n "$RL_5H" || -n "$RL_7D" ]]; then
  # New data arrived — persist it with a timestamp
  printf '%s\n' "${RL_5H:-}" "${RL_7D:-}" "${RL_5H_RESET:-}" > "$INLINE_CACHE"
fi

# ── Account name (cached per session using PPID, TTL 5s) ──
CACHE_FILE="/tmp/.claude-statusline-account-${PPID}"
CACHE_TTL=5
NOW=$(date +%s)
CACHE_VALID=0
if [[ -f "$CACHE_FILE" ]]; then
  CACHE_AGE=$(( NOW - $(stat -f %m "$CACHE_FILE" 2>/dev/null || echo 0) ))
  [[ "$CACHE_AGE" -lt "$CACHE_TTL" ]] && CACHE_VALID=1
fi
if [[ "$CACHE_VALID" -eq 1 ]]; then
  ACCOUNT=$(<"$CACHE_FILE")
else
  ACCOUNT=$(CLAUDECODE= claude auth status 2>/dev/null | python3 -c "import sys,json; e=json.load(sys.stdin).get('email','unknown'); print(e.split('@')[0])" 2>/dev/null)
  [[ -z "$ACCOUNT" ]] && ACCOUNT="unknown"
  echo "$ACCOUNT" > "$CACHE_FILE"
fi

# ── Git status ──
GIT=""
GIT_HI=$'\e[38;2;30;25;45m'
GIT_LO="${LAV_TXT}"
A=$(git rev-list --count @{upstream}..HEAD 2>/dev/null || echo 0)
B=$(git rev-list --count HEAD..@{upstream} 2>/dev/null || echo 0)
S=$(git diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')
M=$(git diff --name-only 2>/dev/null | wc -l | tr -d ' ')
U=$(git ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')
[[ "$A" -gt 0 ]] && GIT+="  ${GIT_HI}⇡${A}${GIT_LO}"
[[ "$B" -gt 0 ]] && GIT+="  ${GIT_HI}⇣${B}${GIT_LO}"
[[ "$S" -gt 0 ]] && GIT+="  ${GIT_HI}+${S}${GIT_LO}"
[[ "$M" -gt 0 ]] && GIT+="  ${GIT_HI}!${M}${GIT_LO}"
[[ "$U" -gt 0 ]] && GIT+="  ${GIT_HI}?${U}${GIT_LO}"

ICON_DIR=$'\ue5ff'
ICON_GIT=$'\ue725'
PL=$'\ue0b0'
E=$'\e'
R="${E}[0m"

# ── ROW1 Colours: dark → lavender → peach segments ──
DARK_BG="${E}[48;2;58;52;72m"
DARK_FG="${E}[38;2;58;52;72m"
DARK_TXT="${E}[38;2;178;170;214m"

LAV_BG="${E}[48;2;178;170;214m"
LAV_FG="${E}[38;2;178;170;214m"
LAV_TXT="${E}[38;2;55;48;68m"

PCH_BG="${E}[48;2;230;210;186m"
PCH_FG="${E}[38;2;230;210;186m"
PCH_TXT="${E}[38;2;72;58;48m"

PCH_MID_BG="${E}[48;2;224;200;177m"
PCH_MID_FG="${E}[38;2;224;200;177m"

PCH2_BG="${E}[48;2;218;190;168m"
PCH2_FG="${E}[38;2;218;190;168m"

PCH3_BG="${E}[48;2;226;196;196m"
PCH3_FG="${E}[38;2;226;196;196m"

MINT_BG="${E}[48;2;176;213;196m"
MINT_FG="${E}[38;2;176;213;196m"
MINT_TXT="${E}[38;2;38;70;55m"

# ══════════════════════════════════════════════════════════════
# ── CUBE 1: usage — inline JSON first, OAuth API as fallback ──
# ══════════════════════════════════════════════════════════════
USAGE_CACHE="/tmp/.claude-statusline-usage-global"
USAGE_BACKOFF="/tmp/.claude-statusline-usage-backoff"
FRESH_TTL=120       # 2 min — show as fresh (5h window changes slowly)
STALE_TTL=900       # 15 min — show with ~ prefix, serve from cache
BACKOFF_TTL=300     # 5 min — after a failed fetch, don't retry
USAGE_AGE=99999
USAGE_VALID=0
USAGE_STALE=0
USED_5H=-1
USED_7D=-1
RESET_TIME=""
INLINE_SOURCE=0

# ── Priority 1: inline rate_limits from current Claude response ──
if [[ -f "$INLINE_CACHE" ]]; then
  INLINE_AGE=$(( NOW - $(stat -f %m "$INLINE_CACHE" 2>/dev/null || echo 0) ))
  # Read the three lines: 5h%, 7d%, resets_at (epoch seconds)
  { read IL_5H; read IL_7D; read IL_RESET; } < "$INLINE_CACHE"
  if [[ -n "$IL_5H" || -n "$IL_7D" ]]; then
    USED_5H=$(printf '%.0f' "${IL_5H:--1}" 2>/dev/null || echo -1)
    USED_7D=$(printf '%.0f' "${IL_7D:--1}" 2>/dev/null || echo -1)
    # Convert epoch to HH:MM
    if [[ -n "$IL_RESET" && "$IL_RESET" =~ ^[0-9]+$ ]]; then
      RESET_TIME=$(date -r "$IL_RESET" +%H:%M 2>/dev/null || echo "")
    fi
    USAGE_AGE="$INLINE_AGE"
    USAGE_STALE=0
    INLINE_SOURCE=1
  fi
fi

# ── Priority 2: OAuth API (existing mechanism — used when no inline data) ──
if [[ "$INLINE_SOURCE" -eq 0 ]]; then
  if [[ -f "$USAGE_CACHE" ]]; then
    USAGE_AGE=$(( NOW - $(stat -f %m "$USAGE_CACHE" 2>/dev/null || echo 0) ))
    if [[ "$USAGE_AGE" -lt "$FRESH_TTL" ]]; then
      USAGE_VALID=1
      USAGE_STALE=0
    elif [[ "$USAGE_AGE" -lt "$STALE_TTL" ]]; then
      USAGE_VALID=1
      USAGE_STALE=1
    fi
  fi
  # If cache expired, check backoff before re-fetching
  if [[ "$USAGE_VALID" -eq 0 && -f "$USAGE_BACKOFF" ]]; then
    BACKOFF_AGE=$(( NOW - $(stat -f %m "$USAGE_BACKOFF" 2>/dev/null || echo 0) ))
    if [[ "$BACKOFF_AGE" -lt "$BACKOFF_TTL" && -f "$USAGE_CACHE" ]]; then
      USAGE_VALID=1
      USAGE_STALE=1
    fi
  fi
  if [[ "$USAGE_VALID" -eq 1 ]]; then
    USAGE_JSON=$(<"$USAGE_CACHE")
  else
    ACCESS_TOKEN=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('claudeAiOauth',{}).get('accessToken',''))" 2>/dev/null)
    FRESH_JSON=""
    if [[ -n "$ACCESS_TOKEN" ]]; then
      FRESH_JSON=$(curl -s --max-time 5 \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "User-Agent: claude-code/2.1.72" \
        "https://api.anthropic.com/api/oauth/usage" 2>/dev/null || echo '')
    fi
    if echo "$FRESH_JSON" | grep -q 'five_hour' 2>/dev/null; then
      USAGE_JSON="$FRESH_JSON"
      USAGE_AGE=0
      USAGE_STALE=0
      echo "$USAGE_JSON" > "$USAGE_CACHE"
      rm -f "$USAGE_BACKOFF"
    elif [[ -f "$USAGE_CACHE" ]]; then
      USAGE_JSON=$(<"$USAGE_CACHE")
      USAGE_STALE=1
      touch "$USAGE_BACKOFF"
    else
      USAGE_JSON='{}'
      USAGE_STALE=1
      touch "$USAGE_BACKOFF"
    fi
  fi

  # Parse five_hour and seven_day from OAuth API response
  read USED_5H USED_7D RESET_TIME <<< $(echo "$USAGE_JSON" | python3 -c "
import sys, json, datetime
d = json.load(sys.stdin)
fh = d.get('five_hour') or {}
sd = d.get('seven_day') or {}
pct5 = fh.get('utilization')
pct7 = sd.get('utilization')
p5 = int(float(pct5)) if pct5 is not None else -1
p7 = int(float(pct7)) if pct7 is not None else -1
reset = fh.get('resets_at', '')
rt = ''
if reset:
    try:
        dt = datetime.datetime.fromisoformat(reset.replace('Z','+00:00'))
        rt = dt.astimezone().strftime('%H:%M')
    except: pass
print(f'{p5} {p7} {rt or \"_\"}')
" 2>/dev/null || echo "-1 -1 _")
  [[ "$RESET_TIME" == "_" ]] && RESET_TIME=""
fi

# Age label for data source
if [[ "$USAGE_AGE" -lt 60 ]]; then
  AGE_LABEL="${USAGE_AGE}s"
elif [[ "$USAGE_AGE" -lt 3600 ]]; then
  AGE_LABEL="$(( USAGE_AGE / 60 ))m"
else
  AGE_LABEL="$(( USAGE_AGE / 3600 ))h"
fi

# 5h label (with ~ prefix when stale)
if [[ "$USED_5H" -ge 0 ]]; then
  if [[ "$USAGE_STALE" -eq 1 ]]; then
    LABEL_5H="~${USED_5H}%"
  else
    LABEL_5H="${USED_5H}%"
  fi
else
  LABEL_5H="n/a"
fi

# 7d label
if [[ "$USED_7D" -ge 0 ]]; then
  if [[ "$USAGE_STALE" -eq 1 ]]; then
    LABEL_7D="~${USED_7D}%"
  else
    LABEL_7D="${USED_7D}%"
  fi
else
  LABEL_7D="n/a"
fi

# ══════════════════════════════════════════════════════════════
# ── ROW2 colours ──
# ══════════════════════════════════════════════════════════════
SQ=$'\u2588'   # █  full block (segment separator)

# Cube 1 — deep slate (API 5h)
SL1_BG="${E}[48;2;42;52;72m"
SL1_FG="${E}[38;2;42;52;72m"
SL1_TXT="${E}[38;2;160;178;214m"
SL1_HI="${E}[38;2;200;210;240m"

# Reset segment — teal-mint
TEL_BG="${E}[48;2;152;210;200m"
TEL_FG="${E}[38;2;152;210;200m"
TEL_TXT="${E}[38;2;32;62;55m"

# Cube 3 — indigo (API 7d)
IND_BG="${E}[48;2;48;42;72m"
IND_FG="${E}[38;2;48;42;72m"
IND_TXT="${E}[38;2;170;160;214m"
IND_HI="${E}[38;2;210;200;240m"

# ══════════════════════════════════════════════════════════════
# ── Build rows ──
# ══════════════════════════════════════════════════════════════
ROW1="${DARK_BG}${DARK_TXT} ${ICON_DIR} ${DIR} ${R}"
ROW1+="${LAV_BG}${DARK_FG}${PL}${LAV_TXT} ${ICON_GIT} ${BRANCH}${GIT} "
ROW1+="${PCH_BG}${LAV_FG}${PL}${PCH_TXT} 󰚩 ${MODEL} "
ROW1+="${MINT_BG}${PCH_FG}${PL}${MINT_TXT} ${ACCOUNT} "
ROW1+="${PCH_MID_BG}${MINT_FG}${PL}${PCH_TXT} 󱎫 ${DUR}m "
ROW1+="${PCH3_BG}${PCH_MID_FG}${PL}${PCH_TXT} 󰧠 ${CTX}% "
ROW1+="${R}${PCH3_FG}${PL}${R}"

# ── ROW2: 5h → reset → 7d ──
# Cube 1: API 5h
ROW2="${SL1_BG}${SL1_TXT} 󱎫 5h ${SL1_HI}${LABEL_5H}${SL1_TXT}  ${AGE_LABEL} "

# Reset segment
if [[ -n "$RESET_TIME" ]]; then
  ROW2+="${TEL_BG}${SL1_FG}${SQ}${TEL_TXT} 󰔟 reset ${RESET_TIME} "
else
  ROW2+="${TEL_BG}${SL1_FG}${SQ}${TEL_TXT} 󰔟 no reset "
fi

# Cube 3: API 7d
ROW2+="${IND_BG}${TEL_FG}${SQ}${IND_TXT} 󰔠 7d ${IND_HI}${LABEL_7D}${IND_TXT} ${R}"

echo $'\u200b'
echo "${ROW1}"
echo $'\u200b'
echo "${ROW2}"
echo $'\u200b'
