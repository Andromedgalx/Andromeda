# Andromeda

A modular **Bash-first local AI terminal** — plugin-driven automation, media management, and lightweight web search.
Designed to run **locally** and interoperate with a local LLM endpoint (example: `mixtral:latest` via Ollama or another local API).

This repository contains only scripts and documentation. **Model files and any private data are never included.**

---

## Table of contents

* [Features](#features)
* [Quick start (local)](#quick-start-local)
* [Requirements](#requirements)
* [Configuration & environment](#configuration--environment)
* [Plugins included](#plugins-included)
* [Usage examples](#usage-examples)
* [Development & testing](#development--testing)
* [GitHub Pages (project site)](#github-pages-project-site)
* [Security & privacy](#security--privacy)
* [Troubleshooting](#troubleshooting)
* [Contributing](#contributing)
* [License](#license)

---

## Features

* Small, readable `andromeda.sh` REPL that routes commands, plugins, memory, and LLM fallbacks.
* Plugin architecture: put executable scripts in `andromeda_plugins/`.
* Bundled / example tools:

  * `media` — media search / play / download using `yt-dlp` + `mpv`.
  * `web_search.py` — lightweight DuckDuckGo HTML scraper with optional local LLM summaries.
* Local memory file (`$HOME/andromeda_memory.db`) for frequently used commands; safe-by-default migration & atomic writes.
* Built-in safety: filters for dangerous command patterns, confirmation prompts, and temp-file cleanup.
* Easy to extend: add scripts in `andromeda_plugins/` and they become available as tools.

---

## Quick start (local)

Clone, make scripts executable, install Python deps, and run.

```bash
git clone https://github.com/<yourname>/<repo>.git
cd <repo>

# Make main script and plugins executable
chmod +x andromeda.sh andromeda_plugins/* || true

# Python deps (for web_search)
python3 -m pip install --user -r requirements.txt

# Start Andromeda
./andromeda.sh
```

### Run with a local LLM (example using Ollama)

This is optional — Andromeda works without an LLM (it will still run intent router & plugins).

```bash
# pseudo-commands - adapt to your LLM host
ollama pull mixtral:latest
ollama run mixtral:latest &    # run model; ensures API at http://localhost:11434
export API=http://localhost:11434/api/generate
export MODEL=mixtral:latest
./andromeda.sh
```

> **Do not** add model files or weights to this repo. See [Security & privacy](#security--privacy).

---

## Requirements

Minimum host dependencies (most are optional depending on which plugins you use):

* `bash` (GNU bash; Linux environment recommended)
* `python3` (for `web_search.py`)
* `pip` (to install Python requirements)
* `yt-dlp` (for media plugin download/search)
* `mpv` (for streaming playback)
* `jq` (optional; improves JSON handling)
* Local LLM endpoint (optional): API compatible with the `API` environment variable format (default `http://localhost:11434/api/generate`).

Install (Debian/Ubuntu example):

```bash
sudo apt update
sudo apt install -y python3 python3-pip mpv jq
python3 -m pip install --user yt-dlp requests
```

---

## Configuration & environment

Default configuration is at the top of `andromeda.sh`. You can override with environment variables before running:

* `MODEL` — model identifier the assistant will request (default `mixtral:latest`).
* `API` — LLM endpoint URL (default `http://localhost:11434/api/generate`).
* `BASE_DIR` — base path for log, memory and plugin directory (defaults to `$HOME`).
* `PLUGIN_DIR` — directory for plugins (defaults to `$HOME/andromeda_plugins`).
* `MEMORY_FILE` — memory database file path (defaults to `$HOME/andromeda_memory.db`).

Example:

```bash
export PLUGIN_DIR="$HOME/my_plugins"
export API="http://127.0.0.1:11434/api/generate"
./andromeda.sh
```

---

## Plugins included

**Plugin pattern**: executable file in `andromeda_plugins/` that accepts positional args. Plugin names must be safe (`[A-Za-z0-9._-]+`).

* `media` — `plugin media <mode> <query|url>`
  Modes: `search`, `play`, `audio`, `video`, `both|download`, `info`, `playlist`.
  Depends on `yt-dlp` and optionally `mpv`.

* `web_search.py` — `web_search "query" [--count N] [--prefer-youtube] [--summary] [--titles N]`
  Depends on Python `requests`. Optionally calls local LLM to produce summaries.

You can add a new plugin by creating an executable script in `andromeda_plugins/`. Example skeleton:

```bash
#!/usr/bin/env bash
# myplugin - short description
set -euo pipefail
MODE="${1:-}"
shift || true

case "${MODE}" in
  help) echo "Usage: myplugin <mode> [args]" ;;
  *) echo "Not implemented" ;;
esac
```

---

## Usage examples

Launch and type commands in the REPL.

* Start Andromeda:

  ```
  ./andromeda.sh
  ```

* List plugins:

  ```
  plugins
  ```

* Use the media plugin:

  ```
  plugin media search "daft punk"
  plugin media play "daft punk - one more time"
  plugin media audio "daft punk one more time"
  ```

* Web search:

  ```
  web_search "linux kernel scheduler" --count 5 --prefer-youtube
  ```

* Ask the model directly:

  ```
  chat What are the top 3 improvements I can make to this script?
  ```

* Enter interactive chat mode:

  ```
  enter-chat
  ```

---

## Development & testing

* Preserve executable bits locally (web UI upload may remove executable flag):

  ```bash
  git update-index --chmod=+x andromeda.sh
  git update-index --chmod=+x andromeda_plugins/*
  git commit -m "Make scripts executable"
  git push
  ```

* Recommended tools:

  * `shellcheck` for bash linting
  * `flake8` for Python linting
  * `pytest` for tests you add

* Suggested CI (GitHub Actions): run `shellcheck` on bash files and `flake8` / `pytest` on Python.

---

## GitHub Pages — project website

You can publish a documentation site from this repo with GitHub Pages.

1. Create `docs/index.md` and paste the docs/overview you want shown.
2. On GitHub → **Settings → Pages**, choose:

   * Source: `main` branch
   * Folder: `/docs`
3. Save. GitHub will publish at `https://<username>.github.io/<repo>/` after a short delay.

Use the `docs/` folder to add plugin docs, screenshots (`docs/images/`), and FAQs.

---

## Security & privacy

* **Do not commit**:

  * `andromeda_memory.db` (memory file)
  * model weights (large binaries)
  * private keys or `.env` files
* Add a `.gitignore` with at least:

  ```
  andromeda_memory.db
  andromeda_memory.db.bak
  Downloads/
  models/
  *.log
  *.tmp
  .env
  ```
* The memory file can contain sensitive commands or metadata. Treat `$HOME/andromeda_memory.db` as private.
* The assistant refuses obviously dangerous patterns (e.g. `rm -rf /`, `mkfs`, `dd`), but **always verify commands produced by an LLM** before execution.
* If you make the repository public, include a `SECURITY.md` and privacy notes describing data handling and contact for reporting issues.

---

## Troubleshooting (common)

* **Plugin appears not executable after cloning**
  Run:

  ```bash
  chmod +x andromeda.sh andromeda_plugins/*
  ```

* **`yt-dlp` missing / errors**
  Install via `pipx install yt-dlp` or your package manager.

* **`mpv` not found**
  Install with your distro package manager (`apt install mpv` or `dnf install mpv`).

* **Ollama or LLM API unreachable**
  Ensure the model host process is running and `API` points to the correct address (`http://localhost:11434/api/generate` by default).

* **Memory migration warnings**
  The script backs up to `${MEMORY_FILE}.bak` and attempts a safe migration. Inspect the backup file if needed.

---

## Contributing

Thanks — contributions are welcome! A few guidelines:

* Keep PRs small and focused.
* Run `shellcheck` for shell files and lint Python before submitting.
* Do not include model weights, memory DB, or secrets.
* Prefer simple, well-tested changes for plugins (add unit tests where applicable).
* Add or update documentation in `docs/` for new plugins and features.

Consider adding an `ISSUE_TEMPLATE.md` / `PULL_REQUEST_TEMPLATE.md` to standardize contributions.

---

## Example systemd unit (optional)

If you want Andromeda to run as a simple service for a user session, here is a sample unit (adapt paths and user):

```ini
[Unit]
Description=Andromeda Local AI Terminal (user service)
After=network.target

[Service]
Type=simple
User=yourusername
WorkingDirectory=/home/yourusername/andromeda
ExecStart=/home/yourusername/andromeda/andromeda.sh
Restart=on-failure
Environment=MODEL=mixtral:latest
Environment=API=http://localhost:11434/api/generate

[Install]
WantedBy=multi-user.target
```

---

## Credits & acknowledgements

* Project inspired by local-first automation patterns and small plugin-driven shells.
* Media plugin uses `yt-dlp` and `mpv`.
* Web-search uses DuckDuckGo HTML scraper (no external JS dependencies).

---

## License

This project is released under the **MIT License**. See the `LICENSE` file for the full text.

---

