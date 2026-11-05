# NotchApp for macOS 15+

A menu that lives under the MacBook notch: hover to open it, move the mouse away to close it. Dark glass look, **two side rails** of sections (main on the left, everything else on the right), and each section has its own height, so the panel never takes more space than needed (Home 600×320, Music 600×280, Pets 600×340). Any section can be detached into its own window with the "window" button in the header or from the menu bar.

## Features

| Section | What it does |
|---|---|
| **Home** | Music, upcoming events, pets and limits, clipboard and shelf at a glance |
| **Music** | Apple Music, Spotify and Yandex Music via AppleScript, **YouTube in Chrome/Safari/Firefox**, local videos in **QuickTime**, and system Now Playing (MediaRemote): artwork, progress, play/pause, ±10 s |
| **Notes** | Multiple notes with a sidebar list, add and delete, autosave. No autocorrect, underlines, smart quotes, substitutions or Writing Tools |
| **Script** | A teleprompter window under the notch that pauses on hover. Both the teleprompter and the notch are hidden from screen recording and sharing (`sharingType = .none`) |
| **Translate** | Offline Apple translation. The source language is detected locally (NaturalLanguage), so there is no "choose a language" prompt, and one session is reused without extra dialogs |
| **Recognize text** | Screenshot (immediately or after 3/5 s), clipboard image, dropped image, voice, or audio/video to text. Vision and Speech run on device; the result goes straight to the clipboard |
| **Clipboard** | Text **and images** (preview, copy back), search, pin, delete. Up to 40 items: the 41st replaces the oldest (pinned items stay). Passwords and transient data are never stored |
| **Shelf** | Drop a file onto the notch to keep it there; open it, reveal it in Finder, or remove it |
| **Calendar** | Events from macOS Calendar, a month grid and a day list |
| **Pets and limits** | Pets for every AI app found on the Mac. Each tile shows a status and its own usage limit; **click a tile to set the limit manually**, use "+" to add your own agent, and see Claude Code usage |
| **Tools** | Lock the keyboard for cleaning, keep awake, run with the lid closed, launch at login |

## Building

```bash
cd NotchApp
./build_app.sh
```

Requires Xcode or Command Line Tools (`xcode-select --install`). The script builds `NotchApp.app`, signs it ad hoc and launches it. If macOS complains about permissions, see the table below.

Build notes:

- `Package.swift` uses `.macOS("15.0")` (the string form), which works with `swift-tools-version:5.9`, unlike `.v15`.
- `swift build --disable-sandbox`: SwiftPM cannot start its own sandbox inside another sandbox (otherwise you get `sandbox-exec: sandbox_apply: Operation not permitted`).
- `build_app.sh` must be executable; if you move the project, run `chmod +x build_app.sh`.

## Permissions

| Feature | Permission |
|---|---|
| Keyboard lock | Accessibility |
| Screenshot to text | Screen Recording |
| Voice to text | Microphone, Speech Recognition |
| Calendar | Calendars |
| Music and QuickTime | Automation (Music, Spotify, QuickTime Player) |
| YouTube in a browser tab | Automation (Google Chrome, Safari, Firefox) |

After a rebuild macOS may forget the Accessibility permission: remove NotchApp from the list and add it again.

## Pets and AI agents

The app listens only on `127.0.0.1:47321`. On launch it finds installed AI apps (/Applications, ~/Applications), their CLI folders (`~/.claude`, `~/.codex`, `~/.gemini`, `~/.cursor`, `~/.copilot`, `~/.kimi`, `~/.deepseek`, `~/.manus`, `~/.opencode`) and running apps.

Currently detected: **DeepSeek Harness**, Claude, OpenCode, Koda Code, ChatGPT, Codex, Cursor, Gemini, Copilot, Grok, DeepSeek, Kimi, Manus (plus Perplexity, Windsurf, Warp, Raycast, Poe, Mistral, Qwen, Ollama and LM Studio if installed). Detection uses both the app name and the bundle ID. You can also add your own agent manually; it is saved between launches.

A tile shows "online" when the app is running, and an agent event ("Done", "Needs permission", "Failed") when the agent sends one to `/event`. That is why DeepSeek Harness appears as a pet: it is running, so it is "online". For it to report "done", you need a hook that calls `/event`.

Right-click a tile to pick a pet, set a manual limit, or send a test notification.

**Done / permission / error:**

```bash
hooks/notch-notify.sh codex done "project built"
hooks/notch-notify.sh cursor permission
hooks/notch-notify.sh myscript error "deploy failed"

curl -X POST 127.0.0.1:47321/event \
  -d '{"agent":"claude","event":"done","message":"done","pet":"🦊"}'
```

**Usage limit in percent** (sent by the agent):

```bash
curl -X POST 127.0.0.1:47321/event \
  -d '{"agent":"codex","remaining":64,"label":"5-hour window"}'
```

**Diagnostics and control:**

```bash
curl 127.0.0.1:47321/health          # is the server alive?
curl 127.0.0.1:47321/state           # notch open?, agents, limits, now playing
curl 127.0.0.1:47321/browser         # what the active Chrome/Safari tab shows
curl 127.0.0.1:47321/ax              # Automation and Accessibility permissions
curl 127.0.0.1:47321/music           # force-refresh Now Playing
curl -X POST 127.0.0.1:47321/open -d '{"tab":"pets"}'   # open a section in a window
```

Sections for `/open`: `home`, `music`, `notes`, `script`, `translate`, `recognize`, `clipboard`, `shelf`, `calendar`, `pets`, `tools`.

### Claude Code

Add the contents of `hooks/claude-settings-example.json` to `~/.claude/settings.json` (fix the path to `notch-notify.sh`). Claude will then send "done" and "needs permission" events. The app estimates 5-hour token usage on its own from local logs in `~/.claude/projects`, roughly and without any network access.

## Keyboard and sleep

- **Clean the keyboard**: locks keys for 30 s / 1 / 2 / 5 min and unlocks automatically. The trackpad can stay enabled so you can click "Unlock". The power button and Touch ID cannot be disabled by software.
- Typing in the notch: clicking a field makes the panel key without activating the app, so ⌘V, arrow keys and normal typing work; there is also a "Paste" button.
- **Keep awake**: an `IOPMAssertion` while the lid is open.
- **Lid closed**: `pmset -a disablesleep 1` (requires an admin password). Sleep is restored when the app quits; macOS may ask for the password again. Don't leave the laptop in a bag, it will heat up.

## Limitations

- AI services have no common limits API: the app shows what agents send to `/event`, plus an approximate Claude Code token count.
- Browser video is detected via system Now Playing or the window title: the active tab in Chrome/Safari, or any window with YouTube in Firefox. Browser automation must be allowed (macOS asks on first use). The detected track is cached so it doesn't flicker between checks.
- Browser controls use JavaScript from Apple Events. In Chrome enable View → Developer → Allow JavaScript from Apple Events; in Safari, Develop → Allow JavaScript from Apple Events. Firefox has no API, so only the track is shown. Telegram round videos are not detected: Telegram doesn't expose the current video, and the window title is the chat name.
- The whole notch (including the teleprompter) is hidden from screen recording with `sharingType = .none`, but some video-call apps capture the screen another way, so check yours.
- The first launch of a terminal build may ask for macOS Automation or Microphone permissions; they are requested on first use.

## License

[MIT](LICENSE) © 2026 Bakhtiyor Sattorov
