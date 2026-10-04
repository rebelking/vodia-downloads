# Vodia User Portal Guide

An interactive end-user guide for the Vodia PBX user portal, in **English and Japanese**. Each topic pairs an annotated screenshot (numbered pins) with matching steps. Visitors can search, share links to any topic, and switch language with one click.

## What's in the box

```
public/                 The website (plain HTML, CSS and JavaScript, no build step)
  index.html            Page shell
  css/style.css         All styling, light and dark mode
  js/app.js             Rendering, search, pins, lightbox, language switch
  data/guide.json       ALL English content: chapters, topics, steps, tips
  data/ui-strings.json  Interface labels (search box, "Good to know", …) that need translating too
  data/i18n/index.json  The extra languages shown in the switch
  data/i18n/ja.json     Japanese: every English sentence → its translation
  data/flags.json       Country flags for the switch
  images/               Screenshots (WebP)
  tools/pin-picker.html Click on a screenshot to create pinned steps
server/server.js        Small web server (Node.js 18+, no dependencies, no API keys)
tools/check-guide.js    Checks content and translations before you deploy
tools/strings.js        Lists text that still needs translating
Dockerfile, docker-compose.yml, .env.example
```

## Run it

You need **Node.js 18 or newer**. There's nothing to install.

```bash
npm start                   # http://localhost:8080
```

Change the port with `PORT=3000 npm start`, or copy `.env.example` to `.env`.

The site is plain static files, so you can also upload `public/` to any web host (nginx, Apache, IIS, S3) instead of running the server.

### With Docker

```bash
docker compose up -d --build
```

### Behind nginx (HTTPS)

Run the guide on port 8080 with `HOST=127.0.0.1`, and proxy to it:

```nginx
server {
    server_name guide.example.com;
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
    }
    # listen 443 ssl; ... (e.g. via certbot)
}
```

## Deploy on a server from GitHub (recommended)

On a fresh Ubuntu or Amazon Linux server with port 80 open, one command installs nginx, pulls the guide from your GitHub repository and serves it on port 80:

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR-USER/YOUR-REPO/main/deploy/install.sh | sudo bash -s -- https://github.com/YOUR-USER/YOUR-REPO.git
```

With a domain and free HTTPS (the domain's DNS must already point at the server, and port 443 must be open):

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR-USER/YOUR-REPO/main/deploy/install.sh | sudo bash -s -- https://github.com/YOUR-USER/YOUR-REPO.git guide.example.com you@example.com
```

**To update,** push your changes to GitHub, then run the same command again on the server. It pulls the latest version, and visitors just refresh.

The repository needs to be **public** for these commands. For a private repository, see "Private repository" below.

### Private repository
1. On the server, run `sudo ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519`, then `sudo cat /root/.ssh/id_ed25519.pub`.
2. On GitHub, go to the repository's **Settings → Deploy keys → Add deploy key**, paste the key, and leave "Allow write access" off.
3. Copy `deploy/install.sh` to the server, then run `sudo bash install.sh git@github.com:YOUR-USER/YOUR-REPO.git`.

## Languages

The switch at the top of the sidebar shows **English** plus every language listed in `data/i18n/index.json`. Visitors whose browser is set to Japanese start in Japanese automatically, and everyone's last choice is remembered.

The translations are fixed files. Nothing is translated on the fly, and nothing calls an outside service.

Screenshots stay in English, so the Japanese text keeps on-screen labels in English with the Japanese in brackets, for example *Settings（設定）*. Users can still match each step to what they see.

### When you edit English text

Changed or new sentences show in English on the Japanese side until they're translated.

1. Run `npm run check`. It reports how many strings are untranslated.
2. Run `npm run strings -- ja > todo.json`. This lists just the missing text as `{ "English": "" }`.
3. Fill in the Japanese, and add those pairs to the `"map"` in `data/i18n/ja.json`.

To fix a translation, edit its line in `ja.json`. Each entry is `"English text": "Japanese text"`.

### Adding another language later

1. Run `npm run strings -- es --all > es-todo.json` to get every string.
2. Translate it, and save it as `data/i18n/es.json` in the form `{ "name": "Español", "code": "es", "map": { … } }`.
3. Add it to `data/i18n/index.json`: `"Español": { "file": "es.json", "code": "es", "flag": "ES" }`.

## Adding and editing content

Everything lives in `public/data/guide.json`:

```jsonc
{
  "title": "Vodia User Portal Guide",
  "subtitle": "How to get around your phone system from the web",
  "chapters": [
    {
      "id": "calling", "title": "Everyday calling", "intro": "Make, move, and look back on your calls.",
      "scenarios": [
        {
          "id": "make-call",                     // used in links: #/calling/make-call
          "title": "Make a call from the dial pad",
          "summary": "One or two sentences under the title.",
          "image": "images/make-call.webp",
          "alt": "What the screenshot shows, for screen readers",
          "caption": "Optional line under the picture.",
          "wide": true,                          // optional: full-width picture, steps underneath
          "narrow": true,                        // optional: for tall, thin screenshots
          "steps": [
            { "text": "Number box. Click it to open the dial pad.", "x": 87.0, "y": 6.4 },  // x/y = pin position in %
            { "text": "A step with no pin." }
          ],
          "tips": ["Shown under “Good to know”."]
        }
      ]
    }
  ]
}
```

For a topic with several screenshots, use `"parts"` instead of `image`/`steps`. Each part has its own `title`, optional `intro`, `image`, `alt`, `caption`, `wide`/`narrow` and `steps`. Parts are shown as stages A, B, C…

### Workflow for a new topic

1. Save the screenshot as WebP in `public/images/`. Crop to the area that matters, and blur anything private (QR codes, real phone numbers, passwords).
2. Open `http://localhost:8080/tools/pin-picker.html`, load the image, click to drop pins, and write each step.
3. Copy the JSON into a new topic in `guide.json`.
4. Run `npm run check`, then translate the new text for Japanese (see above).

**Writing style used so far:** each step starts with the on-screen label, then a period, then what it does ("Save. Nothing changes until you select Save."). Keep it to one or two short sentences.

`public/tools/pin-picker.html` is a helper for you. Delete `public/tools/` before going live if you'd rather not publish it.

## PDF versions

`tools/build_pdf.py` makes printable PDFs from the same content:

```bash
pip install weasyprint pillow          # once; Japanese also needs the Noto Sans CJK JP font
python3 tools/build_pdf.py             # -> dist/Vodia-User-Portal-Guide-EN.pdf (Letter) and -JA.pdf (A4)
```

Run it again after editing `guide.json` or `ja.json`, so the PDFs stay in step with the website.

## Notes

- Topic links (`#/chapter/topic`) are stable as long as you keep the `id`s.
- Third-party notices: see `NOTICE.md`.
