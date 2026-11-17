# Claudy Archive

A local macOS app for browsing, searching, and archiving your Claude Code conversations.

- Automatically finds chats in `~/.claude/projects`, with support for custom history folders.
- Browse by project in a Claude-inspired interface, with formatted messages, images, and expandable tool records.
- Search conversation titles and message text.
- Export a chat, filtered list, or your whole library to ZIP; import archives back into the app.
- Runs entirely on your Mac. No account, API key, or server required. Original history stays unchanged.

## Build and run

Requires **macOS 14+** and Xcode or Command Line Tools with **Swift 5.10+**. No third-party package downloads are needed.

```sh
git clone https://github.com/mrtksn/claudy-archive.git
cd claudy-archive
./build.sh
open 'dist/Claudy Archive.app'
```

You can drag the app into Applications. The build also creates `dist/Claudy Archive-macOS.zip` for the current Mac architecture. Builds are ad-hoc signed, not notarized.

## Archives

Use **Export** (⇧⌘E) and **Import** (⌘O). Archives preserve original session logs, embedded images, and available linked images. Imported copies are kept in the app's own library. ZIPs use the app's versioned format; importing does not create resumable Claude Code sessions.

Archives can contain private messages, credentials, and tool output from the original logs. Missing temporary image files cannot be recovered.

## Tests

```sh
swift test
```

## Related projects

Other tools for browsing or moving coding-agent conversations:

- [Poirot](https://github.com/a7t-ai/poirot) — Native macOS companion for browsing Claude Code sessions, inspecting diffs, and rerunning commands.
- [JustSessions](https://github.com/yangzichao/JustSessions) — Native Mac app for finding, reading, and resuming sessions across Claude Code, Codex, and other agents.
- [Claude Code History Viewer](https://github.com/yanicklandry/claude-code-history-viewer) — Electron desktop viewer with a Claude-style conversation interface, formatted code, and tool records.
- [Coding Agent History Viewer](https://github.com/XZL-CODE/cc-codex-history-viewer) — Tauri desktop app for Claude Code and Codex history, search, exports, and session imports.
- [Claude Session Port](https://github.com/TomSOhm/claude-session-port) — Claude Code slash commands for exporting and importing individual sessions through ZIP files and resuming them on another machine.

## License

[MIT](LICENSE). Independent project; not affiliated with Anthropic.
