#!/usr/bin/env python3
"""Builds printable PDF versions of the guide from public/data.
   python3 tools/build_pdf.py            -> dist/Vodia-User-Portal-Guide-EN.pdf and -JA.pdf
Needs: pip install weasyprint pillow, and the Noto Sans CJK JP font for Japanese."""
import json, html, os, sys
from PIL import Image
import weasyprint

HERE = os.path.dirname(os.path.abspath(__file__))
PUB = os.path.join(HERE, '..', 'public')
OUT = os.path.join(HERE, '..', 'dist')
guide = json.load(open(os.path.join(PUB, 'data', 'guide.json'), encoding='utf-8'))
ja_map = json.load(open(os.path.join(PUB, 'data', 'i18n', 'ja.json'), encoding='utf-8'))['map']
LOGO = open(os.path.join(HERE, 'vodia-logo.svg'), encoding='utf-8').read() if os.path.exists(os.path.join(HERE, 'vodia-logo.svg')) else ''

# Extra print-only labels (not on the website)
PRINT = {
    'en': {'contents': 'Contents', 'how': 'How to read this guide', 'chapter': 'Chapter', 'tips': 'Good to know',
           'date': 'October 2026', 'edition': 'Printed edition', 'page': 'Page',
           'how2': 'Each topic starts with what it is for, then shows the screen with numbered pins. The numbered steps below the picture match the pins.',
           'nopin': 'Steps in a grey circle have no pin on the picture.'},
    'ja': {'contents': '目次', 'how': 'このガイドの見方', 'chapter': '第', 'chapter_suffix': '章', 'tips': '知っておくと便利',
           'date': '2026年10月', 'edition': '印刷版', 'page': 'ページ',
           'how2': '各トピックは、まず目的を説明し、次に番号付きのピンが付いた画面を示します。画像の下の番号付きの手順が、ピンの番号に対応しています。',
           'nopin': 'グレーの丸の手順には、画像上のピンがありません。'},
}

def T(s, lang):
    return ja_map.get(s, s) if lang == 'ja' else s
e = lambda s: html.escape(s or '', quote=True)

def figure(part, lang, max_w_mm=170, max_h_mm=118):
    if not part.get('image'):
        return ''
    path = os.path.join(PUB, part['image'])
    w, h = Image.open(path).size
    if part.get('narrow'):
        max_w_mm = min(max_w_mm, 78); max_h_mm = 150
    elif not part.get('wide'):
        max_w_mm = min(max_w_mm, 150)
    scale = min(max_w_mm / w, max_h_mm / h)
    dw, dh = w * scale, h * scale
    pins = ''.join(
        f'<span class="pin" style="left:{st["x"]}%;top:{st["y"]}%">{i + 1}</span>'
        for i, st in enumerate(part.get('steps', [])) if isinstance(st.get('x'), (int, float)))
    cap = f'<figcaption>{e(T(part["caption"], lang))}</figcaption>' if part.get('caption') else ''
    return (f'<figure class="shot"><div class="frame" style="width:{dw:.1f}mm;height:{dh:.1f}mm">'
            f'<img src="file://{path}" alt="{e(T(part.get("alt", ""), lang))}">{pins}</div>{cap}</figure>')

def steps(part, lang):
    items = []
    for i, st in enumerate(part.get('steps', [])):
        pinned = isinstance(st.get('x'), (int, float))
        items.append(f'<li><span class="num{"" if pinned else " plain"}">{i + 1}</span><p>{e(T(st["text"], lang))}</p></li>')
    return f'<ol class="steps">{"".join(items)}</ol>' if items else ''

def build(lang):
    P = PRINT[lang]
    chap_label = (lambda n: f'{P["chapter"]}{n}{P["chapter_suffix"]}') if lang == 'ja' else (lambda n: f'{P["chapter"]} {n}')
    toc, body = [], []
    for ci, c in enumerate(guide['chapters'], 1):
        cid = f'c-{c["id"]}'
        toc.append(f'<li class="toc-ch"><a href="#{cid}"><span class="n">{ci}</span>{e(T(c["title"], lang))}</a></li>')
        topics = []
        for s in c['scenarios']:
            sid = f's-{s["id"]}'
            toc.append(f'<li class="toc-sc"><a href="#{sid}">{e(T(s["title"], lang))}</a></li>')
            parts = s.get('parts') or [s]
            multi = len(parts) > 1
            inner = []
            for pi, p in enumerate(parts):
                head = ''
                if multi:
                    head = f'<h4><span class="stage">{chr(65 + pi)}</span>{e(T(p.get("title", ""), lang))}</h4>'
                    if p.get('intro'):
                        head += f'<p class="intro">{e(T(p["intro"], lang))}</p>'
                inner.append(f'<section class="part">{head}{figure(p, lang)}{steps(p, lang)}</section>')
            tips = ''
            if s.get('tips'):
                tips = (f'<aside class="tips"><b>{e(P["tips"])}</b><ul>'
                        + ''.join(f'<li>{e(T(t, lang))}</li>' for t in s['tips']) + '</ul></aside>')
            topics.append(f'<article class="topic" id="{sid}"><h3>{e(T(s["title"], lang))}</h3>'
                          f'<p class="summary">{e(T(s["summary"], lang))}</p>{"".join(inner)}{tips}</article>')
        body.append(f'<section class="chapter" id="{cid}"><div class="ch-head"><span class="ch-n">{e(chap_label(ci))}</span>'
                    f'<h2>{e(T(c["title"], lang))}</h2><p>{e(T(c.get("intro", ""), lang))}</p></div>{"".join(topics)}</section>')

    title = T(guide['title'], lang)
    page_size = 'A4' if lang == 'ja' else 'Letter'
    page_h = '296.5mm' if lang == 'ja' else '278.9mm'
    legend = T('Screenshots are marked with numbered pins. Each pin matches a step next to the picture. Select either one to highlight the other, and select a screenshot to enlarge it.', lang)
    legend = legend.split('. ')[0] + '.' if lang == 'en' else legend.split('。')[0] + '。'
    doc = f'''<!doctype html><html lang="{lang}"><head><meta charset="utf-8"><title>{e(title)}</title><style>
@page {{ size: {page_size}; margin: 17mm 17mm 19mm;
  @bottom-left {{ content: string(chap); font-size: 8pt; color: #6B7684; }}
  @bottom-right {{ content: counter(page); font-size: 8pt; color: #6B7684; }} }}
@page cover {{ margin: 0; @bottom-left {{ content: none }} @bottom-right {{ content: none }} }}
@page toc {{ @bottom-left {{ content: none }} }}
html {{ font-family: "Noto Sans CJK JP", "Noto Sans", sans-serif; font-size: 9.6pt; line-height: 1.55; color: #16202B; }}
body {{ margin: 0; }}
{"html { line-break: strict; }" if lang == 'ja' else ''}
a {{ color: inherit; text-decoration: none; }}
.cover {{ page: cover; height: {page_h}; position: relative; background: #FFFFFF; break-after: page; overflow: hidden; }}
.cover .band {{ position: absolute; z-index: 1; left: 0; right: 0; bottom: 0; height: 34%; background: #0B5FA5; }}
.cover .inner {{ position: absolute; left: 22mm; right: 22mm; top: 42mm; }}
.cover svg {{ height: 18mm; width: auto; }}
.cover .vl-red {{ fill: #E2231A; }} .cover .vl-ink {{ fill: #16202B; }}
.cover h1 {{ font-size: 30pt; line-height: 1.15; margin: 16mm 0 5mm; font-weight: 700; letter-spacing: -0.01em; }}
.cover .sub {{ font-size: 13pt; color: #4A5664; margin: 0; }}
.cover .meta {{ position: absolute; z-index: 2; left: 22mm; bottom: 14mm; color: #fff; font-size: 10pt; }}
.cover .meta b {{ display: block; font-size: 12pt; margin-bottom: 1mm; }}
.cover .legend {{ position: absolute; z-index: 2; left: 22mm; right: 22mm; bottom: 46mm; background: #fff; border-radius: 3mm; padding: 6mm 7mm;
  box-shadow: 0 0 0 0.3mm #DDE2E8; }}
.cover .legend h2 {{ font-size: 11pt; margin: 0 0 2mm; }}
.cover .legend p {{ margin: 0 0 2mm; color: #4A5664; font-size: 9pt; }}
.legend .row {{ display: flex; gap: 3mm; align-items: center; margin-top: 2.5mm; font-size: 9pt; }}
.toc {{ page: toc; break-after: page; }}
.toc h2 {{ font-size: 20pt; margin: 0 0 6mm; }}
.toc ol {{ list-style: none; padding: 0; margin: 0; }}
.toc li a::after {{ content: leader('.') target-counter(attr(href), page); color: #6B7684; }}
.toc-ch {{ font-weight: 700; font-size: 11pt; margin: 4.5mm 0 1.5mm; }}
.toc-ch .n {{ display: inline-block; width: 7mm; color: #0B5FA5; }}
.toc-sc {{ margin: 0.8mm 0 0.8mm 7mm; color: #2B3743; }}
.chapter {{ break-before: page; }}
.ch-head {{ border-bottom: 0.6mm solid #0B5FA5; padding-bottom: 4mm; margin-bottom: 6mm; }}
.ch-head h2 {{ string-set: chap content(text); font-size: 22pt; line-height: 1.2; margin: 1mm 0 2mm; }}
.ch-n {{ color: #0B5FA5; font-weight: 700; font-size: 10pt; letter-spacing: 0.04em; text-transform: uppercase; }}
.ch-head p {{ margin: 0; color: #4A5664; font-size: 11pt; }}
.topic {{ margin: 0 0 9mm; }}
.topic + .topic {{ border-top: 0.3mm solid #DDE2E8; padding-top: 7mm; }}
.topic {{ }}
.topic h3 {{ font-size: 15pt; line-height: 1.25; margin: 0 0 2mm; color: #0B2E4F; break-after: avoid; }}
.summary {{ color: #4A5664; margin: 0 0 4mm; font-size: 10pt; break-after: avoid; }}
.part {{ margin: 0 0 5mm; }}
.part h4 {{ display: flex; align-items: center; gap: 2.5mm; font-size: 11pt; margin: 5mm 0 1.5mm; break-after: avoid; }}
.stage {{ display: inline-block; width: 5.5mm; height: 5.5mm; line-height: 5.5mm; text-align: center; border-radius: 1.4mm;
  background: #0B5FA5; color: #fff; font-size: 8.5pt; font-weight: 700; }}
.intro {{ margin: 0 0 3mm 8mm; color: #4A5664; break-after: avoid; }}
.shot {{ margin: 0 0 3.5mm; break-inside: avoid; break-after: avoid; }}
.frame {{ position: relative; border: 0.25mm solid #CDD4DC; border-radius: 1.5mm; overflow: hidden; }}
.frame img {{ display: block; width: 100%; height: 100%; }}
.pin {{ position: absolute; width: 5.4mm; height: 5.4mm; margin: -2.7mm 0 0 -2.7mm; border-radius: 50%; background: #F5B301;
  border: 0.45mm solid #fff; color: #1A1400; font-size: 7.5pt; font-weight: 700; line-height: 4.5mm; text-align: center; }}
figcaption {{ font-size: 8pt; color: #6B7684; margin-top: 1.2mm; }}
.steps {{ list-style: none; padding: 0; margin: 0; }}
.steps li {{ display: flex; gap: 2.8mm; margin: 0 0 1.8mm; break-inside: avoid; }}
.num {{ flex: none; width: 5.2mm; height: 5.2mm; line-height: 5.2mm; text-align: center; border-radius: 50%; background: #F5B301;
  color: #1A1400; font-size: 7.5pt; font-weight: 700; margin-top: 0.4mm; }}
.num.plain {{ background: #E8ECF0; color: #4A5664; }}
.steps p {{ margin: 0; }}
.tips {{ border-left: 0.8mm solid #0B5FA5; background: #F2F6FA; padding: 3mm 4mm; margin-top: 4mm; break-inside: avoid; }}
.tips b {{ display: block; margin-bottom: 1mm; color: #0B2E4F; }}
.tips ul {{ margin: 0; padding-left: 4.5mm; color: #2B3743; }}
.tips li {{ margin: 0.6mm 0; }}
</style></head><body>
<section class="cover"><div class="inner">{LOGO}<h1>{e(title)}</h1><p class="sub">{e(T(guide["subtitle"], lang))}</p></div>
<div class="legend"><h2>{e(P["how"])}</h2><p>{e(P["how2"])}</p>
<div class="row"><span class="num">1</span><span>{e(legend)}</span></div>
<div class="row"><span class="num plain">2</span><span>{e(P["nopin"])}</span></div></div>
<div class="band"></div><div class="meta"><b>{e(P["edition"])}</b>{e(P["date"])}</div></section>
<section class="toc"><h2>{e(P["contents"])}</h2><ol>{"".join(toc)}</ol></section>
{"".join(body)}
</body></html>'''
    os.makedirs(OUT, exist_ok=True)
    name = os.path.join(OUT, f'Vodia-User-Portal-Guide-{lang.upper()}.pdf')
    weasyprint.HTML(string=doc, base_url=PUB).write_pdf(name, optimize_images=True, jpeg_quality=82, dpi=200)
    return name

if __name__ == '__main__':
    for lang in (sys.argv[1:] or ['en', 'ja']):
        print('wrote', build(lang))
