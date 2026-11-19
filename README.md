# 📚 Course AI Study Buddy

A free AI study helper for students that runs on your own Mac. Paste course notes (or load a PDF) and get:

- 💬 **Ask the tutor**: a chat that answers questions using your course material
- 📝 **Summary**: key points, a short paragraph, an exam revision sheet, or "explain like I'm 12"
- ❓ **Quiz**: interactive multiple-choice questions with scoring and explanations
- 🃏 **Flashcards**: cards you click to flip
- 📊 **Test log**: success rate, speed and which AI answered each request, exportable to CSV. Use it to judge whether the free API is good enough for your course.

It costs nothing to run. Behind the scenes it uses **[FreeLLMAPI](https://github.com/tashfeenahmed/freellmapi)**, an open-source router that combines the free tiers of many AI providers (Google Gemini, Groq, Cerebras, Mistral, OpenRouter and more). If one provider is busy or out of free quota, it moves on to the next one automatically.

## Install on a Mac (one command)

Open **Terminal** (press ⌘ Space, type "Terminal", press Enter), paste this line and press Enter:

```bash
curl -fsSL https://raw.githubusercontent.com/khleeq92-netizen/FreeLLM/claude/lucid-sagan-282tpm/install.sh | bash
```

The first install takes about 3–6 minutes. When it finishes, the app opens in your browser at **http://127.0.0.1:3100**.

You don't need anything else installed and you don't need admin rights. Everything goes into one folder, `~/CourseAI`. If your Mac doesn't have Node.js, a private copy is downloaded into that folder.

## Daily use

| To… | Do this |
|---|---|
| Start | Double-click **Course AI** on your Desktop (or run `~/CourseAI/start.sh`) |
| Stop | Run `~/CourseAI/stop.sh` |
| Update | Run the install command again. Your keys, data and password are kept. |
| Remove everything | Run `~/CourseAI/uninstall.sh` |

> First time you double-click **Course AI.command**, macOS may ask whether to open it. Click **Open**. If it is blocked, right-click it, choose **Open**, then **Open** again.

## Getting better answers (optional, free)

The app works straight away using FreeLLMAPI's **no-signup providers**. For faster and smarter answers, add one or more **free** keys under **⚙️ Settings** in the app. None of them needs a credit card:

| Provider | Get a free key |
|---|---|
| Google Gemini (recommended) | https://aistudio.google.com/apikey |
| Groq (very fast) | https://console.groq.com/keys |
| Cerebras (very fast) | https://cloud.cerebras.ai/ |
| OpenRouter | https://openrouter.ai/keys |
| Mistral | https://console.mistral.ai/api-keys |

You can also pass keys in during install:

```bash
curl -fsSL https://raw.githubusercontent.com/khleeq92-netizen/FreeLLM/claude/lucid-sagan-282tpm/install.sh | GEMINI_API_KEY=your-key GROQ_API_KEY=your-key bash
```

## How it fits together

```
Browser ──► Study Buddy (127.0.0.1:3100) ──► FreeLLMAPI router (127.0.0.1:3001) ──► free AI providers
             app/server.mjs + index.html       picks a free model, falls back       Gemini, Groq, Mistral…
                                               when one is rate-limited
```

- Both services listen on **127.0.0.1 only**, so other computers on your network can't reach them.
- Provider keys are stored encrypted inside FreeLLMAPI (`~/CourseAI/data`). The browser never sees them.
- The FreeLLMAPI dashboard (http://127.0.0.1:3001) shows every model, usage and analytics. Its login is printed at the end of the install and shown in **⚙️ Settings**.

## Testing whether it's good enough for your course

1. Load a real chapter (Load file → PDF), or click **Try a sample lesson**.
2. Try each tab a few times, and switch **AI mode** between *Fast*, *Smartest available* and *Fusion*.
3. Open **📊 Test log** to see the success rate, average response time and which providers answered. Click **Export CSV** to share the results.

Things to know: free tiers have daily limits that reset at midnight UTC, quality can dip late in the day as the best models run out, and response speed varies by provider. That's fine for a pilot or a small class, but a large class or a graded product should add a paid provider as a backup.

## Options

Set these before `bash` in the install command (for example `... | COURSEAI_PORT=4000 bash`):

| Variable | Default | Meaning |
|---|---|---|
| `COURSEAI_HOME` | `~/CourseAI` | Install folder |
| `COURSEAI_PORT` | `3100` | Study Buddy port (the next free port is used if this one is busy) |
| `FREELLMAPI_PORT` | `3001` | FreeLLMAPI port (the next free port is used if this one is busy) |
| `FREELLMAPI_REF` | `main` | FreeLLMAPI branch or tag to install |
| `COURSEAI_NO_OPEN` | `0` | `1` = don't open the browser |
| `COURSEAI_NO_START` | `0` | `1` = install only |

## Troubleshooting

- **"No AI models yet"**: the no-signup providers appear after FreeLLMAPI's first catalog sync, which needs internet and can take a minute. Or just add a free Gemini key in ⚙️ Settings.
- **"No free AI provider could answer right now"**: the free limits are used up or the providers are busy. Wait a bit, switch AI mode, or add another free key.
- **Logs**: `~/CourseAI/logs/` (`build.log`, `freellmapi.log`, `app.log`).

## For developers

| Path | What it is |
|---|---|
| `app/server.mjs` | Zero-dependency Node server: serves the UI and forwards requests to FreeLLMAPI |
| `app/public/index.html` | The whole UI (vanilla HTML/CSS/JS) |
| `installer/install.template.sh` | Installer source |
| `install.sh` | **Generated** with `node scripts/build-installer.mjs` (embeds the app files). Don't edit it by hand. |
| `tests/mock-provider.mjs` | Fake OpenAI-compatible provider for testing offline |
| `tests/ui-test.cjs` | Playwright browser test of every tab |
