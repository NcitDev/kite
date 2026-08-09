# Installing Kite

Kite is a macOS Telegram client with an AI agent built into the composer.

## Requirements

- macOS 10.13 or later
- Apple silicon or Intel (the build is universal)

## Install

1. Download `Kite-<version>.dmg`.
2. Open it and drag **Kite** to Applications.
3. **The first launch needs an extra step** — see below.

## First launch

Kite is signed, but with an ad-hoc signature rather than an Apple Developer ID, and it is
not notarized. macOS will refuse to open it on the first try:

> "Kite" Not Opened — Apple could not verify "Kite" is free of malware that may harm your
> Mac or compromise your privacy.

**On macOS 15 (Sequoia) and later — including macOS 26 — Control-clicking and choosing Open
no longer works.** Apple removed that bypass. Use one of these instead.

**Through System Settings:**

1. Double-click Kite, then click **Done** on the dialog. This one attempt is required; the
   option below does not appear until macOS has blocked the app once.
2. Open **System Settings → Privacy & Security** and scroll to the **Security** section.
3. Next to *"Kite" was blocked to protect your Mac*, click **Open Anyway**.
4. Authenticate, then click **Open Anyway** once more.

**Or from the Terminal**, which skips all of the above:

```sh
xattr -dr com.apple.quarantine /Applications/Kite.app
```

**Or use the script in the disk image**, which is the quickest route. `Install Kite.command`
copies Kite to Applications, clears the flag, launches it, and closes itself. It cannot be
double-clicked — macOS blocks downloaded scripts too, for the same reason it blocks the app.
Open Terminal, type `bash ` including the trailing space, drag the script in, press Return.

Either way, only the first launch needs it. The flag is applied by the browser that
downloaded the file, so a copy moved off this machine by other means may not need it at all.

## Connecting an agent

Kite talks to coding agents over [ACP](https://agentclientprotocol.com) (Agent Client
Protocol) and starts the agent as a child process. Configure this in
**Settings → Profiles & Automation**. Supported out of the box:

| Agent    | Command                                    |
| -------- | ------------------------------------------ |
| Codex    | `npx -y @agentclientprotocol/codex-acp`    |
| Claude   | `npx -y @zed-industries/claude-code-acp`   |
| opencode | `opencode acp`                             |

Any other ACP-speaking agent can be pointed at with a custom command. Once connected, Kite
asks the agent which models it offers and lets you pick a different one per chat action.

### If an agent fails to start

Kite reports the agent's stderr in the settings screen. The two usual causes:

- **The agent is not on `PATH`.** Apps launched from Finder get a minimal `PATH`. Kite
  already prepends the common install locations (`~/.bun/bin`, `~/.local/bin`,
  `/opt/homebrew/bin`, `/usr/local/bin` and others), but an agent installed elsewhere needs
  its absolute path in the command field.
- **A quarantined helper binary.** Agents that unpack native modules at startup (opencode
  does this) can have those files blocked by Gatekeeper. Clearing quarantine on the agent's
  install directory fixes it.

## Local voice transcription

Voice-to-text can run entirely on your machine against any OpenAI-compatible transcription
endpoint. With [whisper.cpp](https://github.com/ggerganov/whisper.cpp):

```sh
whisper-server -m ~/.whisper-models/ggml-base.bin \
  --host 127.0.0.1 --port 8080 \
  --inference-path /v1/audio/transcriptions \
  --convert -l auto
```

Then enable local transcription in **Settings → Profiles & Automation** and point it at
`http://127.0.0.1:8080/v1/audio/transcriptions`.

## Upgrading from TelegramWork

Kite was previously called TelegramWork. Because the app group container is derived from the
bundle identifier, the first launch after upgrading moves your accounts and cache from the
old container to the new one automatically. Quit TelegramWork before launching Kite the
first time — both reading the same database at once can corrupt it.
