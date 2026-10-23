# Third-party notices

**بالعربية:** هذا الملف يسجّل حقوق الطرف الثالث في الملفات الموزّعة. النصوص القانونية تبقى بالإنجليزية كما وردت من أصحابها.

This installer is MIT licensed — see [LICENSE](LICENSE), Copyright (c) 2026 Mahmoud Alkhatib.
One shipped file is a modified copy of someone else's MIT-licensed work, and the MIT
licence asks that their notice travel with it. It is reproduced below.

## prompts-ar/tag_prompt.tmpl

Modified from `default_prompts/tag_prompt.tmpl` in
[icereed/paperless-gpt](https://github.com/icereed/paperless-gpt) v0.29.0. The
instruction text and the XML-like data block come from upstream; the output-format
rules that pin the tag separator to the ASCII comma are additions for Arabic.

```
MIT License

Copyright (c) 2024 Icereed

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

`prompts-ar/ocr_prompt.tmpl` is written from scratch for Arabic documents; it keeps
only the `{{.Content}}` conditional that paperless-gpt requires of any OCR template.

## Not redistributed here

Everything the stack actually runs is downloaded by the installer from its own
upstream registry on your machine. No copy of it is included in this installer, and
each component keeps its own licence:

| Component | Pinned default | Upstream licence |
|---|---|---|
| Paperless-ngx | `ghcr.io/paperless-ngx/paperless-ngx:3.3.0` | GPL-3.0 |
| Paperless-GPT | `docker.io/icereed/paperless-gpt:v0.29.0` | MIT |
| PostgreSQL | `docker.io/library/postgres:18.6` | PostgreSQL Licence |
| Valkey | `docker.io/valkey/valkey:9.1.2-alpine` | BSD-3-Clause |
| Gotenberg | `docker.io/gotenberg/gotenberg:8.37.0` | MIT |
| Apache Tika | `docker.io/apache/tika:3.3.1.0` | Apache-2.0 |
| Traefik (VPS target) | `docker.io/traefik:v3.7.11` | MIT |
| Ollama (local-AI target) | `docker.io/ollama/ollama:0.40.2` | MIT |
| Docker Engine | installed via `get.docker.com` when missing | Apache-2.0 |
| Tesseract Arabic data | `tesseract-ocr-ara`, inside the Paperless-ngx image | Apache-2.0 |

Local AI models (`qwen3:8b`, `qwen2.5vl:7b`) are pulled by Ollama under their own
model licences. Cloud AI mode sends document text to the provider you choose
(OpenRouter, Gemini or OpenAI) under that provider's terms, using your own API key.
