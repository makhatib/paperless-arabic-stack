# Paperless Arabic Stack

**Paperless-ngx + Paperless-GPT, set up for Arabic documents, in one command.**

Your paper invoices, letters and receipts become a searchable archive. An AI model
reads the Arabic text out of phone photos and scans, and fills in the title, sender,
date and tags for you.

🇸🇦 **بالعربية:** [README.ar.md](README.ar.md)

---

## Quick start

```bash
git clone <repo-url> paperless-arabic-stack
cd paperless-arabic-stack
chmod +x install.sh
./install.sh
```

The installer asks a handful of questions, then does everything else: installs Docker
if it is missing, generates every password, creates the admin user, creates the API
token and wires Paperless-GPT to Paperless-ngx with no copy/paste, and downloads the
AI models.

Re-running `./install.sh` is always safe. It keeps your answers and your data.

---

## What you need

### Prerequisites

| | |
|---|---|
| Operating system | Ubuntu 22.04 / 24.04 / 25.04, or Debian 12. Other Linux works if you install Docker yourself. |
| CPU architecture | amd64 (normal PC/server) or arm64 (Raspberry Pi 5, Apple silicon VM, Ampere VPS) |
| Root access | Yes — to install Docker and to bind ports 80/443 in VPS mode |
| Docker | Installed for you if missing (official `get.docker.com` script) |
| Internet | Needed during install, and on every boot of the Paperless container (it installs the tesseract language pack each time) |

### Recommended specs

The AI part is what decides your specs. Everything else is light.

| Setup | CPU | RAM | Disk | What to expect |
|---|---|---|---|---|
| **Paperless-ngx only (no AI)** | 2 cores | 4 GB | 20 GB | 14–16 s per page. Perfectly usable. |
| **Cloud AI** (OpenRouter / OpenAI / Gemini) | 2 cores | 4 GB | 20 GB | ~10 s per document. Best accuracy. Costs ≈ **$1.3 per 1000 documents**. Your documents leave your server. |
| **Local AI, CPU only** | 4 cores | **16 GB** | 40 GB | ~3 min for metadata, **6–8 min to read one photo**. Nothing leaves your server. |
| **Local AI, NVIDIA GPU** | 4 cores | 16 GB | 40 GB | **under 1 minute** to read one photo. Same accuracy as CPU, just faster. |

**GPU notes**

- 8 GB of VRAM holds one model. The stack uses two (text + vision) and swapping
  them costs about 15 seconds each time, so **16 GB VRAM** is the comfortable number.
- You need the **NVIDIA Container Toolkit** installed, not just the driver. Without it
  the installer tells you and falls back to the CPU.
- `OLLAMA_KEEP_ALIVE` is set to `60m` automatically when a GPU is used. Loading a
  model off disk takes ~15 s and a GPU does not speed that up — on a GPU that load is
  most of the total time, so keeping the model resident matters more than you expect.

**RAM is about the vision model, not about Paperless.** We measured a peak of 7.8 GB
for `qwen2.5vl:7b`. On a 24 GB machine memory was never close to full — the
bottleneck was the CPU.

---

## The two install targets

### 1. VPS with a domain

- Traefik gets free SSL certificates from Let's Encrypt automatically.
- You get `https://docs.yourdomain.com` (the archive) and
  `https://ai-docs.yourdomain.com` (the AI screen).
- **Create the DNS records first.** The installer shows you exactly what to add and
  waits for you. Two `A` records pointing at your server's public IP:

  ```
  docs.yourdomain.com      A    <your server IP>
  ai-docs.yourdomain.com   A    <your server IP>
  ```

  Let's Encrypt verifies those names over port 80, so they must resolve before a
  certificate can be issued.
- Paperless-GPT is put behind a password (HTTP basic auth), because it has no login
  screen of its own. The installer generates that password and shows it to you once.
- Ports 80 and 443 must be free.

### 2. HomeLab / local machine

- No domain, no SSL. You open it as `http://<machine-ip>:8000`.
- Paperless-GPT is bound to **127.0.0.1 only** by default, so nothing on your network
  can reach it. You can opt into LAN exposure, and the installer warns you clearly
  that this means *no password at all*.
- Do not port-forward any of this to the internet. If you want access from outside,
  use a VPN (WireGuard or Tailscale).

---

## The four tags

Paperless-GPT watches for tags. Put a tag on a document in Paperless-ngx and the AI
picks it up within seconds.

| Tag | What happens |
|---|---|
| `paperless-gpt` | Suggests title / sender / date / tags and **waits for you to approve** on the AI screen. |
| `paperless-gpt-auto` | Same, but saves immediately without asking. |
| `paperless-gpt-ocr-auto` | **Re-reads the page with the vision model.** This is the one that fixes Arabic phone photos. |
| `paperless-gpt-failed` | Added automatically when something fails. Nothing for you to do. |

> **Only use `ocr-auto` on images and scans.** A PDF that already contains text is read
> by Paperless-ngx at 100% accuracy, instantly and for free. Running AI OCR on it makes
> the result *worse*.

### Your first test

1. Photograph any invoice and drop the file into `./consume/` (or upload it from the
   web page). It appears in a few seconds.
2. Open the document, add the tag `paperless-gpt-ocr-auto`, save. Wait.
3. Re-open it and read the text, then search for a number printed on it.

On our Arabic test invoice, plain OCR found **1 of 26 numbers**. The local vision model
found **25 of 26**. A cloud model found **26 of 26** in 10 seconds.

---

## Models

| | Text model | Vision model (reads images) |
|---|---|---|
| **Local (CPU or GPU)** | `qwen3:8b` | `qwen2.5vl:7b` |
| **Cloud (OpenRouter)** | `google/gemini-3.1-flash-lite` | same |

**Do not use `minicpm-v`.** It is the model suggested in the upstream Paperless-GPT
docs, and on Arabic it is a disaster: it fell into a repetition loop, produced 7286
characters for a 437-character document, and scored **1.8% similarity — worse than not
using AI at all** — after running 5.7× longer than the model that worked.

To change models, edit `PAS_TEXT_MODEL` / `PAS_VISION_MODEL` in `.env` and run
`./install.sh`.

---

## Commands

```bash
./install.sh                 # install, or re-apply an existing install (safe to repeat)
./install.sh status          # what is running, where, disk used, certificate state
./install.sh update          # pull the pinned images again and restart
./install.sh backup          # DB + documents + prompts/config -> ./backups
./install.sh restore <file>  # restore from a backup archive
./install.sh uninstall       # stop everything (your documents are kept)
./install.sh help
```

Add `--yes` to run without any questions, using the values already in `.env`.

### Updating to a newer release

Image versions are **pinned** in `.env` (`PAS_V_NGX`, `PAS_V_GPT`, …) so that
`update` is reproducible and never surprises you. To move to a newer release:

```bash
nano .env                    # change PAS_V_NGX=3.3.0 to the version you want
./install.sh update          # takes a database backup first, then pulls and restarts
```

### Backups

`./install.sh backup` produces one `.tar.gz` in `./backups/` containing:

- a `pg_dump` of the database
- the `media` volume (your original files, archived PDFs, thumbnails)
- the `data` volume (search index, classifier model)
- `prompts/`, `config/`, `db/`, `compose.yaml` and `.env`

**The archive contains `.env`, which contains every password.** Keep it private, and
copy it off the machine — a backup that only exists on the same server is not a backup.

Test your restore. `./install.sh restore <file>` is there for exactly that, and we
test it on every release of this script.

---

## Troubleshooting

**Paperless-ngx takes forever to start the first time.**
Normal. The container installs the Arabic tesseract package on every boot, which needs
internet. First boot is the slow one (1–2 minutes). If your server has no internet at
boot time, Arabic OCR silently goes missing — this is a known upstream behaviour.

**`./install.sh` says a port is busy.**
It offers you a different one. Nothing is started before you pick.

**The AI never does anything after I add a tag.**
```bash
docker compose logs -f paperless-gpt
```
The usual causes: the model has not finished downloading
(`docker compose exec ollama ollama list`), or the API key is wrong in cloud mode.

**Reading one photo takes 8 minutes.**
That is the measured, correct speed on 4 CPU cores with no GPU. It is not broken. Use
a GPU or the cloud option if you need it faster.

**I get empty fields with a "thinking" model.**
Models like `gpt-oss:20b` spend their token budget on internal reasoning before
answering. Raise `TOKEN_LIMIT` in `compose.yaml` before blaming the model.

**My GPU seems to be running at CPU speed.**
Check whether the model actually fits:
```bash
docker compose exec ollama curl -s http://localhost:11434/api/ps
```
If `size_vram` is smaller than `size`, part of the model spilled onto the CPU. There is
no warning when this happens. Lower `OLLAMA_MAX_LOADED_MODELS` or use a bigger card.

**Let's Encrypt is not issuing a certificate.**
```bash
docker compose logs traefik | grep -i acme
```
Almost always one of: the DNS record does not point here yet, port 80 is blocked by a
firewall or another service, or you hit the Let's Encrypt rate limit (5 failures per
hour per domain — use `PAS_LE_STAGING=yes` while you debug).

**Everything suddenly 404s after I edited something.**
Run `./install.sh` again. It regenerates and validates `compose.yaml` before replacing
the live file, and restores the previous one if the new one is broken.

---

## Known limits — read these before you rely on it

These are measured results, not guesses. They do not get fixed by a bigger model.

1. **An English invoice number inside an Arabic line can be stored in a different
   digit order than it is printed.** This is a right-to-left text problem across the
   whole photo → read → store chain. Searching for the correct number will not find
   that document. We tested this on a live system: three documents about one invoice,
   and no single search term found all three. **No setting fixes it.** Search for both
   orders.
2. **Document linking does not work reliably on Arabic documents**, for the same
   reason — it relies on literal text matching of a reference code.
3. **Auto-tagging invents overlapping tags.** It created both `تجارة` and `تجاري` for
   one concept, and tagged a payment-reminder letter as `فاتورة ضريبية` (tax invoice),
   which it is not. Recommendation: leave `CREATE_NEW_TAGS=true` for your first batch,
   review what it invented, then set it to `false` in `compose.yaml` and let the model
   pick from your clean list.
4. **The same company can end up as two separate correspondents** — one Arabic, one
   English — on bilingual documents. Merge them by hand early.
5. **Dates can be the wrong date.** The model has confused an invoice due date with the
   document date. Check the date on documents that matter.
6. **Arabic text inside the generated PDF is invisible when you highlight it.** The
   Paperless image ships no Arabic font. The text is still searchable and copyable;
   only the highlight box looks empty.
7. **A cloud model fixes reading mistakes, not organising mistakes.** It corrected the
   name, sender and date in our tests. It did *not* fix duplicate tags, duplicate
   correspondents, the RTL number problem, or document linking. Do not buy a stronger
   model to solve a structural problem.

**This is an excellent archiving assistant. It is not a source of truth for financial
numbers.** Treat every extracted amount as a suggestion until a human confirms it.

---

## Security

Read this part. It is short.

- **Paperless-GPT has no authentication of its own.** Anyone who can reach its port
  sees your documents. That is why VPS mode always puts basic auth in front of it and
  HomeLab mode binds it to `127.0.0.1`.
- **`.env` holds every password** and is created with `chmod 600`. It is in
  `.gitignore`. Never commit it, never paste it into a chat or an issue.
- **Your backups contain `.env`.** Same rules.
- **In VPS mode, Traefik mounts the Docker socket read-only.** This is the standard
  Traefik setup and is what lets it read the routing labels. Be aware that read access
  to the Docker socket is still a privileged thing: anyone who gets code execution
  inside the Traefik container can enumerate your containers. If you want to tighten
  this, put a `docker-socket-proxy` in front of it.
- **Cloud mode sends your documents to a third party** — the page image and the
  extracted text of everything you process. Do not use it for documents you are not
  allowed to send off your server. Local mode sends nothing anywhere.
- **HomeLab mode is plain HTTP with no encryption.** Do not port-forward it. Use a VPN.
- The installer generates every secret randomly. It never ships a default password.

---

## What is installed

| Service | Image | Role |
|---|---|---|
| webserver | `ghcr.io/paperless-ngx/paperless-ngx:3.3.0` | the app, OCR, task queue |
| db | `postgres:18.6` | database |
| broker | `valkey/valkey:9.1.2-alpine` | task queue (Redis-compatible) |
| gotenberg | `gotenberg/gotenberg:8.37.0` | Office / `.eml` → PDF |
| tika | `apache/tika:3.3.1.0` | text extraction from Office files |
| paperless-gpt | `icereed/paperless-gpt:v0.29.0` | the AI layer |
| ollama | `ollama/ollama:0.40.2` | runs local models (local AI only) |
| traefik | `traefik:v3.7.11` | TLS and routing (VPS only) |

All versions are pinned. Nothing uses `latest`.

---

## Sources

Everything above was verified against the official documentation for these exact
versions, or measured on a real server:

- Paperless-ngx: <https://github.com/paperless-ngx/paperless-ngx/blob/v3.3.0/docs/configuration.md>,
  <https://docs.paperless-ngx.com>
- Paperless-GPT: <https://github.com/icereed/paperless-gpt> — README,
  `docs/openai_compatible_providers.md`, `docs/document_linking.md`
- Style and UX modelled on <https://github.com/makhatib/AI-stack> (`install-advanced.sh`)

---

```
أرشفة مستنداتك العربية بالذكاء الاصطناعي
Your Arabic documents, searchable with AI

YouTube: https://youtube.com/@malkhatib
```
