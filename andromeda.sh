#!/usr/bin/env bash
# andromeda.sh — Fixed main script (handles memory plugin invocations correctly)
set -euo pipefail
IFS=$'\n\t'

### Config ###
MODEL="${MODEL:-mixtral:latest}"
API="${API:-http://localhost:11434/api/generate}"

BASE_DIR="${HOME}"
MEMORY_FILE="${BASE_DIR}/andromeda_memory.db"
MEMORY_BACKUP="${BASE_DIR}/andromeda_memory.db.bak"
LOG_FILE="${BASE_DIR}/andromeda.log"
PLUGIN_DIR="${BASE_DIR}/andromeda_plugins"
SYSTEM_PROFILE_FILE="${BASE_DIR}/andromeda_system_profile"

SAFE_PREFIXES=( "free" "df" "du" "uptime" "whoami" "pwd" "date" "ls" "ps" "top" )
DANGEROUS_TOKENS=( "rm -rf" "mkfs" "dd " "shutdown" "reboot" "poweroff" ":(){" "chmod -R 777 /" ">/dev" "chown -R root:root /" )

if ! command -v curl >/dev/null 2>&1; then
  echo "ERROR: curl is required. Install it and retry." >&2
  exit 1
fi
_has_jq() { command -v jq >/dev/null 2>&1; }

mkdir -p "$PLUGIN_DIR"
touch "$MEMORY_FILE"
touch "$LOG_FILE"

# ---------- Helpers ----------
log(){ printf "[%s] %s\n" "$(date --iso-8601=seconds)" "$*" | tee -a "$LOG_FILE"; }
normalize_key(){ local s="$*"; printf "%s" "$(echo "$s" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"; }
list_plugins(){ (cd "$PLUGIN_DIR" && ls -1 2>/dev/null) || true; }

# ---------- Memory ----------
migrate_memory_if_needed(){
  if awk -F'|' 'NF==2{exit 0} END{exit 1}' "$MEMORY_FILE"; then
    log "Migrating memory -> 4-field format (backup: $MEMORY_BACKUP)"
    cp -a "$MEMORY_FILE" "$MEMORY_BACKUP"
    awk -F'|' 'BEGIN{OFS=FS}{ if(NF==2) print $1,$2,1,systime(); else print $0 }' "$MEMORY_BACKUP" > "${MEMORY_FILE}.tmp" && mv -f "${MEMORY_FILE}.tmp" "$MEMORY_FILE"
    log "Migration complete."
  fi
}

memory_save_or_update(){
  local KEY="$1"; shift
  local CMD="$*"
  [[ -z "$KEY" || -z "$CMD" ]] && return 1
  if printf "%s" "$CMD" | grep -qiE 'COMMAND_NOT_FOUND|Hello! I'\''m Andromeda|largest_files'; then
    log "Skipping suspicious memory entry: $CMD"
    return 0
  fi
  local existing
  existing=$(awk -F'|' -v k="$KEY" 'BEGIN{IGNORECASE=1} { if(tolower($1)==tolower(k)){print; exit}}' "$MEMORY_FILE" || true)
  if [[ -n "$existing" ]]; then
    IFS='|' read -r _k ecmd ecount ets <<< "$existing"
    ecount=${ecount:-0}; newcount=$((ecount+1))
    awk -F'|' -v k="$KEY" -v nc="$newcount" -v ts="$(date +%s)" 'BEGIN{OFS=FS} { if(tolower($1)==tolower(k)){ $3=nc; $4=ts } print }' "$MEMORY_FILE" > "${MEMORY_FILE}.tmp" && mv -f "${MEMORY_FILE}.tmp" "$MEMORY_FILE"
    log "Memory updated: $KEY -> $ecmd (uses $newcount)"
  else
    printf "%s|%s|%d|%s\n" "$KEY" "$CMD" 1 "$(date +%s)" >> "$MEMORY_FILE"
    log "Memory saved: $KEY -> $CMD"
  fi
}

memory_lookup_and_mark(){
  local KEY="$1"
  local entry
  entry=$(awk -F'|' -v k="$KEY" 'BEGIN{IGNORECASE=1} { if(tolower($1)==tolower(k)){print; exit}}' "$MEMORY_FILE" || true)
  if [[ -z "$entry" ]]; then return 1; fi
  IFS='|' read -r k cmd count ts <<< "$entry"
  count=${count:-0}; newcount=$((count+1))
  awk -F'|' -v k="$KEY" -v nc="$newcount" -v ts="$(date +%s)" 'BEGIN{OFS=FS} { if(tolower($1)==tolower(k)){ $3=nc; $4=ts } print }' "$MEMORY_FILE" > "${MEMORY_FILE}.tmp" && mv -f "${MEMORY_FILE}.tmp" "$MEMORY_FILE"
  printf "%s" "$cmd"
  return 0
}

memory_top(){ awk -F'|' 'NF==4{printf "%6s x  %s -> %s\n",$3,$1,$2}' "$MEMORY_FILE" | sort -nr | sed -n '1,40p'; }
memory_search(){ local TERM="$*"; if [[ -z "$TERM" ]]; then echo "Usage: memory-search <term>"; return 1; fi; grep -i -- "$TERM" "$MEMORY_FILE" | awk -F'|' '{printf "%s -> %s (uses: %s)\n",$1,$2,$3}' | sed -n '1,40p'; }

# ---------- Plugins ----------
run_plugin(){
  local name="$1"; shift || true
  local script="$PLUGIN_DIR/$name"
  if [[ ! -f "$script" ]]; then echo "Plugin '$name' not found in $PLUGIN_DIR."; list_plugins; return 1; fi
  if [[ ! -x "$script" ]]; then echo "Plugin '$name' not executable. chmod +x \"$script\""; return 2; fi
  log "Running plugin $name with args: $*"
  "$script" "$@"
  return $?
}
call_plugin_capture(){ local name="$1"; shift; local script="$PLUGIN_DIR/$name"; if [[ ! -x "$script" ]]; then return 2; fi; "$script" "$@"; }

# ---------- Ollama ----------
call_ollama(){
  local prompt="$1"
  local safe_prompt
  safe_prompt=$(printf "%s" "$prompt" | sed 's/"/\\"/g' | sed 's/\t/ /g')
  local payload
  payload=$(printf '{"model":"%s","prompt":"%s","stream":false}' "$MODEL" "$safe_prompt")
  local out
  out=$(curl -sS -X POST -H "Content-Type: application/json" -d "$payload" "$API" || echo "")
  if _has_jq; then
    echo "$out" | jq -r '.response // .text // ""' 2>/dev/null || echo "$out"
  else
    echo "$out" | sed -n 's/.*"response"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed -n '1p' || echo "$out"
  fi
}

# ---------- Auto-correct plugin misuse ----------
KNOWN_MEDIA_MODES=(play audio video both info playlist search download)
auto_correct_plugin_misuse(){
  local cmd="$1"
  if printf "%s" "$cmd" | grep -qiE '^[[:space:]]*plugin[[:space:]]+media'; then
    local tail="${cmd#*media }"; tail="$(printf "%s" "$tail" | sed 's/^[[:space:]]*//')"
    local first
    first=$(printf "%s" "$tail" | awk '{
      if (match($0,/^"([^"]+)"/)) { print substr($0,RSTART+1,RLENGTH-2); exit }
      if (match($0,/^'\''([^'\'']+)'\''/)) { print substr($0,RSTART+1,RLENGTH-2); exit }
      print $1; exit }')
    local first_lc; first_lc="$(printf "%s" "$first" | tr '[:upper:]' '[:lower:]')"
    for m in "${KNOWN_MEDIA_MODES[@]}"; do if [[ "$first_lc" == "$m" ]]; then echo "$cmd"; return 0; fi; done
    if printf "%s" "$tail" | grep -qE '^["'\''].*["'\'']$'; then
      echo "plugin media play $tail"
    else
      local esc; esc=$(printf "%s" "$tail" | sed 's/"/\\"/g')
      echo "plugin media play \"$esc\""
    fi
    return 0
  fi
  if printf "%s" "$cmd" | grep -qiE '^[[:space:]]*plugin[[:space:]]+'; then
    local tmp="${cmd#plugin }"; local maybe="$(printf "%s" "$tmp" | awk '{print $1}')"
    if [[ ! -f "$PLUGIN_DIR/$maybe" ]]; then echo "$(printf "%s" "$cmd" | sed -E 's/^[[:space:]]*plugin[[:space:]]+//I')"; return 0; fi
  fi
  echo "$cmd"
  return 0
}

# ---------- Intent router (keeps deterministic commands fast) ----------
intent_router(){
  local input="$1"; local lc; lc=$(printf "%s" "$input" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

  if printf "%s" "$lc" | grep -qiE '(largest|biggest).*(file|files)'; then
    local dir="/home/$(whoami)"; if printf "%s" "$input" | grep -oE '/[^ ]+' >/dev/null 2>&1; then dir="$(printf "%s" "$input" | grep -oE '/[^ ]+' | head -n1)"; fi
    log "Intent Router: largest files -> $dir"
    bash -c "du -ah \"$dir\" 2>/dev/null | sort -rh | head -n 20"
    memory_save_or_update "$(normalize_key "$input")" "du -ah \"$dir\" | sort -rh | head -n 20"
    return 0
  fi

  if printf "%s" "$lc" | grep -qiE '(^| )(disk|disk usage|storage|df|du)'; then
    log "Intent Router: df -h"
    df -h || true
    memory_save_or_update "$(normalize_key "$input")" "df -h"
    return 0
  fi

  if printf "%s" "$lc" | grep -qiE '(^| )(memory|ram|free)'; then
    log "Intent Router: free -h"
    free -h || true
    memory_save_or_update "$(normalize_key "$input")" "free -h"
    return 0
  fi

  if printf "%s" "$lc" | grep -qiE '(^| )(top processes|top|processes|ps aux|running processes)'; then
    log "Intent Router: ps aux"
    ps aux --sort=-%cpu | head -n 20 || true
    memory_save_or_update "$(normalize_key "$input")" "ps aux --sort=-%cpu | head -n 20"
    return 0
  fi

  if printf "%s" "$lc" | grep -qiE '^(play|stream|watch)[[:space:]]+'; then
    local q; q=$(printf "%s" "$input" | sed -E 's/^[[:space:]]*(play|stream|watch)[[:space:]]+//I')
    log "Intent Router: media.play -> $q"
    if [[ -x "$PLUGIN_DIR/web_search" ]]; then
      local web_out url
      web_out=$(call_plugin_capture web_search "$q" --count 6 --prefer-youtube 2>/dev/null || true)
      url=$(printf "%s" "$web_out" | grep -Eo 'https?://(www\.)?(youtube\.com|youtu\.be)[^ ]+' | head -n1 || true)
      if [[ -n "$url" ]]; then
        if command -v mpv >/dev/null 2>&1; then
          echo "Playing: $url"
          mpv --ytdl=yes --ytdl-format=best "$url"
          memory_save_or_update "$(normalize_key "$input")" "plugin media play \"$q\""
          return 0
        else
          run_plugin media both "$url"
          memory_save_or_update "$(normalize_key "$input")" "plugin media both \"$q\""
          return 0
        fi
      fi
    fi
    run_plugin media play "$q"
    memory_save_or_update "$(normalize_key "$input")" "plugin media play \"$q\""
    return 0
  fi

  if printf "%s" "$lc" | grep -qiE '^(download|save|get)[[:space:]]+'; then
    if printf "%s" "$lc" | grep -qi 'audio'; then local q; q=$(printf "%s" "$input" | sed -E 's/.*audio[[:space:]]+//I'); run_plugin media audio "$q"; memory_save_or_update "$(normalize_key "$input")" "plugin media audio \"$q\""; return 0
    elif printf "%s" "$lc" | grep -qi 'video'; then local q; q=$(printf "%s" "$input" | sed -E 's/.*video[[:space:]]+//I'); run_plugin media video "$q"; memory_save_or_update "$(normalize_key "$input")" "plugin media video \"$q\""; return 0
    else local q; q=$(printf "%s" "$input" | sed -E 's/^(download|save|get)[[:space:]]+//I'); run_plugin media download "$q"; memory_save_or_update "$(normalize_key "$input")" "plugin media download \"$q\""; return 0; fi
  fi

  if printf "%s" "$lc" | grep -qiE '^(search|find|look up|lookup|what is|who is|google)[[:space:]]*'; then
    local q; q=$(printf "%s" "$input" | sed -E 's/^(search|find|look up|lookup|google)[[:space:]]*//I'); [[ -z "$q" ]] && q="$input"
    log "Intent Router: web_search -> $q"
    run_plugin web_search "$q" --count 6 --prefer-youtube
    memory_save_or_update "$(normalize_key "$input")" "plugin web_search \"$q\""
    return 0
  fi

  if printf "%s" "$lc" | grep -qiE '(^| )(scan network|network scan|scan devices|nmap|hosts)'; then
    log "Intent Router: network_scan"
    if [[ -x "$PLUGIN_DIR/network_scan" ]]; then run_plugin network_scan || echo "network_scan failed"; else echo "network_scan plugin not available"; fi
    memory_save_or_update "$(normalize_key "$input")" "plugin network_scan"
    return 0
  fi

  if printf "%s" "$lc" | grep -qiE '(^| )(temp|temperature|cpu temp|sensors)'; then
    log "Intent Router: system_info temps"
    if [[ -x "$PLUGIN_DIR/system_info" ]]; then run_plugin system_info temps || sensors || true; else sensors || echo "sensors not available"; fi
    memory_save_or_update "$(normalize_key "$input")" "plugin system_info temps"
    return 0
  fi

  return 1
}

# ---------- Prepare ----------
generate_system_profile(){ { printf "OS: %s\n" "$(uname -s) $(lsb_release -ds 2>/dev/null || echo '')"; printf "Kernel: %s\n" "$(uname -r)"; } > "$SYSTEM_PROFILE_FILE" 2>/dev/null || true; }
migrate_memory_if_needed

# ---------- utility to execute a command or plugin string safely ----------
execute_command(){
  # Handles:
  #  - plugin <name> [mode] [args]
  #  - run_plugin <name> [mode] [args]
  #  - arbitrary shell commands (fallback to bash -c)
  local cmd="$1"
  cmd="$(printf "%s" "$cmd" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  # plugin invocation?
  if printf "%s" "$cmd" | grep -q -E '^[[:space:]]*(plugin|run_plugin)[[:space:]]+'; then
    # strip prefix
    local rest="${cmd#* }"
    # parse plugin name, optional mode, args (simple parsing)
    if [[ "$rest" =~ ^([^\ ]+)([[:space:]]+([^\ ]+))?[[:space:]]*(.*)$ ]]; then
      local pname="${BASH_REMATCH[1]}"
      local pmode="${BASH_REMATCH[3]:-}"
      local pargs="${BASH_REMATCH[4]:-}"
      if [[ -f "$PLUGIN_DIR/$pname" && -x "$PLUGIN_DIR/$pname" ]]; then
        if [[ -n "$pmode" ]]; then
          log "Executing plugin (from memory/AI): $pname $pmode $pargs"
          "$PLUGIN_DIR/$pname" "$pmode" "$pargs"
          return $?
        else
          log "Executing plugin (from memory/AI): $pname $pargs"
          "$PLUGIN_DIR/$pname" "$pargs"
          return $?
        fi
      else
        echo "Plugin '$pname' not found or not executable."
        return 2
      fi
    else
      echo "Could not parse plugin invocation: $cmd"
      return 3
    fi
  fi

  # Otherwise run as a shell command
  bash -c "$cmd"
  return $?
}

# ---------- REPL ----------
echo "======================================="
echo "   ANDROMEDA — Local AI Terminal"
echo "======================================="
echo "Type 'help' for commands. 'exit' to quit.'"
echo ""

while true; do
  read -e -p "Andromeda> " USER_INPUT_RAW || { echo; break; }
  USER_INPUT="${USER_INPUT_RAW:-}"
  USER_INPUT="$(printf "%s" "$USER_INPUT" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ -z "$USER_INPUT" ]] && continue

  case "$USER_INPUT" in
    exit|quit) echo "Goodbye."; break ;;
    help)
      cat <<'EOF'
Built-in:
  help
  plugins | list-plugins
  plugin <name> [mode] [args]
  show-memory
  memory | top-memory
  memory-search <term>
  clear-memory
  chat <message>
  enter-chat
  exit | quit
EOF
      continue
      ;;
    plugins|list-plugins) echo "Plugins in $PLUGIN_DIR:"; list_plugins; continue ;;
    show-memory) echo "Raw memory file: $MEMORY_FILE"; nl -ba "$MEMORY_FILE" 2>/dev/null || true; continue ;;
    memory|top-memory) memory_top; continue ;;
    memory-search*) term="${USER_INPUT#memory-search }"; memory_search "$term"; continue ;;
    clear-memory) read -r -p "Really clear memory cache (y/n)? " yn; if [[ "$yn" =~ ^[Yy]$ ]]; then : > "$MEMORY_FILE"; echo "Memory cleared."; else echo "Cancelled."; fi; continue ;;
    chat*) rest="${USER_INPUT#chat }"; if [[ -z "$rest" ]]; then echo "Usage: chat <message>"; else call_ollama "$rest"; fi; continue ;;
    enter-chat)
      echo "Entering chat mode (/exit to quit)."
      while true; do
        read -e -p "Chat> " CHAT_INPUT || break
        [[ "$CHAT_INPUT" == "/exit" ]] && break
        call_ollama "$CHAT_INPUT"
      done
      continue
      ;;
  esac

  # manual plugin invocation
  if [[ "$USER_INPUT" =~ ^plugin([[:space:]]+|$) ]]; then
    rest="${USER_INPUT#plugin }"; rest="$(printf "%s" "$rest" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if [[ -z "$rest" ]]; then echo "Available plugins:"; list_plugins; continue; fi
    if [[ "$rest" =~ ^([^\ ]+)([[:space:]]+([^\ ]+))?[[:space:]]*(.*)$ ]]; then
      PLNAME="${BASH_REMATCH[1]}"; MODE="${BASH_REMATCH[3]:-}"; ARGS_REST="${BASH_REMATCH[4]:-}"
    else
      echo "Usage: plugin <name> [mode] [args]"; continue
    fi
    if [[ ! -f "$PLUGIN_DIR/$PLNAME" ]]; then echo "Plugin '$PLNAME' not found."; list_plugins; continue; fi
    if [[ ! -x "$PLUGIN_DIR/$PLNAME" ]]; then echo "Plugin '$PLNAME' not executable. chmod +x \"$PLUGIN_DIR/$PLNAME\""; continue; fi
    if [[ -n "$MODE" ]]; then log "Running plugin $PLNAME mode='$MODE' args='$ARGS_REST'"; "$PLUGIN_DIR/$PLNAME" "$MODE" "$ARGS_REST"; else log "Running plugin $PLNAME args='$ARGS_REST'"; "$PLUGIN_DIR/$PLNAME" "$ARGS_REST"; fi
    continue
  fi

  # treat questions as chat
  if [[ "$USER_INPUT" =~ \?$ ]]; then call_ollama "$USER_INPUT"; continue; fi

  # memory lookup
  KEY=$(normalize_key "$USER_INPUT")
  mem_cmd=$(memory_lookup_and_mark "$KEY" || true)
  if [[ -n "$mem_cmd" ]]; then
    COMMAND="$mem_cmd"
    log "Memory hit: '$KEY' -> $COMMAND"
    lowercmd="$(printf "%s" "$COMMAND" | tr '[:upper:]' '[:lower:]')"
    blocked=false
    for tok in "${DANGEROUS_TOKENS[@]}"; do if [[ "$lowercmd" == *"$tok"* ]]; then echo "⚠️ Refusing to run potentially dangerous command: $tok"; blocked=true; break; fi; done
    [[ "$blocked" == true ]] && continue

    # Auto-run safe prefixes or execute plugin properly
    AUTO_RUN=false
    for p in "${SAFE_PREFIXES[@]}"; do if printf "%s" "$COMMAND" | grep -q -E "^${p}([[:space:]]|$)"; then AUTO_RUN=true; break; fi; done

    if [[ "$AUTO_RUN" == true ]]; then
      echo "⚡ Auto-running: $COMMAND"
      execute_command "$COMMAND"
    else
      read -r -p "Execute this command from memory? (y/n): " yn
      if [[ "$yn" =~ ^[Yy]$ ]]; then execute_command "$COMMAND"; fi
    fi
    continue
  fi

  # intent router
  if intent_router "$USER_INPUT"; then continue; fi

  # AI fallback
  SYSTEM_PROMPT=$(
cat <<'PROMPT'
You are Andromeda, a local Linux assistant.
Rules:
1) Return exactly one shell command (single line) when asked to provide a command.
2) Output only that command, nothing else.
3) Prefer shell commands for local tasks; use plugins only when appropriate.
4) If you cannot produce a safe single command, output: COMMAND_NOT_FOUND
PROMPT
  )
  FULL_PROMPT="$SYSTEM_PROMPT
User request: $USER_INPUT"
  log "Querying model for: $USER_INPUT"
  AI_TEXT=$(call_ollama "$FULL_PROMPT" || echo "")
  if [[ -z "$AI_TEXT" ]]; then echo "AI returned no response."; continue; fi

  # Extract command (backticks first, else first non-empty line)
  COMMAND=$(printf "%s" "$AI_TEXT" | awk -F'`' 'NF>1{print $2; exit}')
  if [[ -z "$COMMAND" ]]; then COMMAND=$(printf "%s" "$AI_TEXT" | awk 'NF && $0 !~ /^(Note|Hint|Explanation)/{print; exit}'); fi
  COMMAND="$(printf "%s" "$COMMAND" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [[ -z "$COMMAND" ]]; then echo "AI could not produce a single command. AI text:"; printf "%s\n" "$AI_TEXT"; continue; fi

  COMMAND="$(auto_correct_plugin_misuse "$COMMAND")"
  memory_save_or_update "$KEY" "$COMMAND"

  lowercmd="$(printf "%s" "$COMMAND" | tr '[:upper:]' '[:lower:]')"
  blocked=false
  for tok in "${DANGEROUS_TOKENS[@]}"; do if [[ "$lowercmd" == *"$tok"* ]]; then echo "🚨 Refusing to run potentially dangerous command containing: '$tok'"; blocked=true; break; fi; done
  [[ "$blocked" == true ]] && continue

  # If plugin invocation, execute via run_plugin parsing
  if printf "%s" "$COMMAND" | grep -q -E '^[[:space:]]*plugin[[:space:]]+'; then
    execute_command "$COMMAND"
    continue
  fi

  # Auto-run safe commands, else ask confirmation
  AUTO_RUN=false
  for p in "${SAFE_PREFIXES[@]}"; do if printf "%s" "$COMMAND" | grep -q -E "^${p}([[:space:]]|$)"; then AUTO_RUN=true; break; fi; done
  if [[ "$AUTO_RUN" == true ]]; then
    echo "⚡ Auto-running safe command: $COMMAND"
    execute_command "$COMMAND"
  else
    read -r -p "Execute this command? (y/n): " CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then execute_command "$COMMAND"; else echo "Cancelled."; fi
  fi

done
