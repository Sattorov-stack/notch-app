#!/bin/bash
# Подключает ИИ-агентов к питомцам в чёлке:
#   • Claude Code — хуки Stop («Готово») и Notification («Нужно разрешение»)
#   • Codex — уведомление о завершении хода (прежний обработчик Computer Use сохраняется)
# Перед изменением настроек делает резервные копии рядом (*.bak-notch).
set -e
DIR="$HOME/.notchapp"
mkdir -p "$DIR"

# --- общий отправитель события в чёлку ---
cat > "$DIR/notch-notify.sh" <<'EOF'
#!/bin/bash
# notch-notify.sh <агент> <done|permission|error|info> [сообщение]
AGENT="${1:-ai}"
EVENT="${2:-done}"
MSG=$(printf '%s' "${3:-}" | tr '\n' ' ' | sed 's/\\/\\\\/g; s/"/\\"/g' | cut -c1-160)
curl -s -m 2 -X POST "http://127.0.0.1:47321/event" \
  -H 'Content-Type: application/json' \
  -d "{\"agent\":\"$AGENT\",\"event\":\"$EVENT\",\"message\":\"$MSG\"}" >/dev/null 2>&1 || true
exit 0
EOF

# --- хук Claude Code: берёт текст уведомления из JSON на входе ---
cat > "$DIR/claude-hook.sh" <<'EOF'
#!/bin/bash
EVENT="${1:-done}"
INPUT=$(cat)
MSG=$(printf '%s' "$INPUT" | sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
"$HOME/.notchapp/notch-notify.sh" claude "$EVENT" "$MSG"
exit 0
EOF

chmod +x "$DIR/notch-notify.sh" "$DIR/claude-hook.sh"

# --- Claude Code: аккуратно дописываем хуки в settings.json ---
CLAUDE="$HOME/.claude/settings.json"
mkdir -p "$HOME/.claude"
[ -f "$CLAUDE" ] && cp "$CLAUDE" "$CLAUDE.bak-notch"
python3 - "$CLAUDE" <<'PY'
import json, os, sys
path = sys.argv[1]
data = {}
if os.path.exists(path):
    with open(path) as f:
        text = f.read().strip()
        data = json.loads(text) if text else {}
hooks = data.setdefault("hooks", {})
home = os.path.expanduser("~")
want = {
    "Stop": f"{home}/.notchapp/claude-hook.sh done",
    "Notification": f"{home}/.notchapp/claude-hook.sh permission",
}
for event, cmd in want.items():
    groups = hooks.setdefault(event, [])
    exists = any(h.get("command") == cmd for g in groups for h in g.get("hooks", []))
    if not exists:
        groups.append({"hooks": [{"type": "command", "command": cmd}]})
with open(path, "w") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
print("Claude Code: хуки на месте")
PY

# --- Codex: notify допускает одну команду, поэтому делаем обёртку,
#     которая вызывает прежний обработчик и потом питомца ---
CODEX="$HOME/.codex/config.toml"
if [ -f "$CODEX" ]; then
    cp "$CODEX" "$CODEX.bak-notch"
    python3 - "$CODEX" "$DIR" <<'PY'
import json, re, sys, os
path, d = sys.argv[1], sys.argv[2]
text = open(path).read()
wrapper = f"{d}/codex-notify.sh"
m = re.search(r'^notify\s*=\s*(\[.*?\])\s*$', text, re.M)
if m and wrapper in m.group(1):
    print("Codex: уже подключён")
    sys.exit(0)
original = json.loads(m.group(1)) if m else []
lines = ["#!/bin/bash",
         "# Codex notify: сначала прежний обработчик, потом питомец в чёлке"]
if original:
    quoted = " ".join("'" + a.replace("'", "'\\''") + "'" for a in original)
    lines.append(f'{quoted} "$@" >/dev/null 2>&1 &')
lines.append('"$HOME/.notchapp/notch-notify.sh" codex done "ход завершён"')
lines.append("exit 0")
open(wrapper, "w").write("\n".join(lines) + "\n")
os.chmod(wrapper, 0o755)
new_line = f'notify = ["{wrapper}"]'
text = text[:m.start()] + new_line + text[m.end():] if m else new_line + "\n" + text
open(path, "w").write(text)
print("Codex: подключён через обёртку, прежний обработчик сохранён")
PY
fi

echo "✓ Готово. Проверка: $DIR/notch-notify.sh claude done \"проверка\""
