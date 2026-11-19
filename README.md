# 🤖 FreeLLM Assistant

A personal AI assistant that runs on your own Mac and uses **free** AI models. Upload your files and it can:

- 💬 **Chat**: answer questions using the files you tick (Excel, Word, PDF, text)
- ✍️ **Write**: emails, notices, letters, posts, reports, proposals, or rewrite your text, in any tone, length and language
- 🌐 **Translate**: pasted text or whole documents (English, Hindi, Urdu, Marathi, Arabic and 20+ more)
- 📄 **Summarise**: key points, an executive summary, action items, or simple words; long documents are read in parts
- 📊 **Excel / Data**: preview a spreadsheet, ask questions about it, or have the AI edit every row (translate a column, add a category, clean up text) and download a new **.xlsx**
- 📈 **Log**: success rate, speed and which AI answered each request

Results can be copied or downloaded as Word (.doc) or text. Your files, chat and log are kept in the browser between visits.

It costs nothing to run. Behind the scenes it uses **[FreeLLMAPI](https://github.com/tashfeenahmed/freellmapi)**, an open-source router that combines the free tiers of many AI providers. If one is busy or out of quota, it moves on to the next one automatically.

## Install on a Mac (one command)

Open **Terminal** (press ⌘ Space, type "Terminal", press Enter), paste this line and press Enter:

```bash
curl -fsSL https://raw.githubusercontent.com/khleeq92-netizen/FreeLLM/claude/lucid-sagan-282tpm/install.sh | bash
```

The first install takes about 3–6 minutes, then the app opens at **http://127.0.0.1:3100**. You don't need anything else installed and you don't need admin rights. Everything goes into `~/FreeLLM-Assistant`.

If you installed the earlier **Course AI** version, the installer copies its keys and data across automatically. After that you can delete the old `~/CourseAI` folder.

## Daily use

| To… | Do this |
|---|---|
| Start | Double-click **FreeLLM Assistant** on your Desktop (or run `~/FreeLLM-Assistant/start.sh`) |
| Stop | Run `~/FreeLLM-Assistant/stop.sh` |
| Update | Run the install command again. Your keys, data and password are kept. |
| Remove everything | Run `~/FreeLLM-Assistant/uninstall.sh` |

## Faster answers (strongly recommended, free)

Without keys, answers come from no-signup providers and can take 10–60 seconds. Add a **free** key under **⚙️ Settings** to get answers in a few seconds. No credit card is needed:

| Provider | Get a free key |
|---|---|
| Google Gemini (recommended) | https://aistudio.google.com/apikey |
| Groq (very fast) | https://console.groq.com/keys |
| Cerebras (very fast) | https://cloud.cerebras.ai/ |
| OpenRouter | https://openrouter.ai/keys |
| Mistral | https://console.mistral.ai/api-keys |

## ⚠️ Privacy: read before using real data

Files are read **on your computer**, but the text you send with a question goes to whichever free AI provider answers it. **Free tiers may use what you send to improve their models.** Do **not** send student records, Aadhaar or phone numbers, fee details of named students, staff personal data, or trading account credentials through free providers. Use sample or anonymised data for testing. Sensitive data needs a paid provider with a no-training agreement, or a model running on your own computer.

## How it fits together

```
Browser ──► Assistant (127.0.0.1:3100) ──► FreeLLMAPI router (127.0.0.1:3001) ──► free AI providers
            app/server.mjs + index.html      picks a free model, falls back       Gemini, Groq, Mistral…
            (file readers run in browser)    when one is rate-limited
```

- Both services listen on **127.0.0.1 only**, so other computers on your network can't reach them.
- Provider keys are stored encrypted inside FreeLLMAPI (`~/FreeLLM-Assistant/data`). The browser never sees them.
- FreeLLMAPI dashboard: http://127.0.0.1:3001. Its login is shown in **⚙️ Settings**.

## Limits of this version

- Single user, on one computer. There are no logins or roles yet.
- Scanned PDFs (images of text), photos and chart screenshots aren't read yet.
- Excel edits are done by the AI row by row (up to 2,000 rows). Check the result before using it officially.
- Answers about numbers use exact column totals the app computes, but always double-check important figures.

## Options

Set these before `bash` in the install command (for example `... | APP_PORT=4000 bash`):

| Variable | Default | Meaning |
|---|---|---|
| `ASSISTANT_HOME` | `~/FreeLLM-Assistant` | Install folder |
| `APP_PORT` | `3100` | Assistant port (the next free port is used if this one is busy) |
| `FREELLMAPI_PORT` | `3001` | FreeLLMAPI port (the next free port is used if this one is busy) |
| `FREELLMAPI_REF` | `main` | FreeLLMAPI branch or tag to install |
| `GEMINI_API_KEY`, `GROQ_API_KEY`, … | — | Free keys to add during install |
| `ASSISTANT_NO_OPEN` / `ASSISTANT_NO_START` | `0` | `1` = don't open the browser / install only |

## Troubleshooting

- **"No AI models yet"**: the no-signup providers appear about a minute after the first start. Or add a free Gemini key in ⚙️ Settings.
- **"No free AI provider could answer right now"**: free limits are used up or providers are busy. Wait, switch AI mode, or add another free key.
- **A file says "Could not read"**: save Word files as .docx, and scanned PDFs aren't supported yet.
- **Logs**: `~/FreeLLM-Assistant/logs/` (`build.log`, `freellmapi.log`, `app.log`).

## For developers

| Path | What it is |
|---|---|
| `app/server.mjs` | Zero-dependency Node server: serves the UI and file-reader libraries, and forwards requests to FreeLLMAPI |
| `app/public/index.html` | The whole UI (vanilla HTML/CSS/JS) |
| `app/package.json` | Browser file readers: SheetJS (Excel), mammoth (Word), pdf.js (PDF) |
| `installer/install.template.sh` | Installer source |
| `install.sh` | **Generated** with `node scripts/build-installer.mjs`. Don't edit it by hand. |
| `tests/mock-provider.mjs` | Fake OpenAI-compatible provider for testing offline |
| `tests/ui-test.cjs` | Playwright test: uploads Excel, Word and PDF, then uses every tab |
