#!/usr/bin/env python3
"""Generate the ch-gov architecture diagrams from the architecture-diagram skill template.

Usage:  python3 docs/diagrams/build.py [OUT_DIR]     # OUT_DIR defaults to this directory

Reads the template, logos and icons from the architecture-diagram skill at
~/.claude/skills/architecture-diagram/resources. Edit this file rather than the
generated HTML: every run rewrites all four pages.
"""
import re, sys, html
from pathlib import Path

SKILL = Path.home() / ".claude/skills/architecture-diagram/resources"
OUT = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent
TEMPLATE = (SKILL / "template.html").read_text()
LOGOS = (SKILL / "logos.html").read_text()
ICONS = (SKILL / "icons.html").read_text()

K = {
    'fe':  ('rgba(0, 203, 235, 0.16)',  '#00cbeb'),
    'be':  ('rgba(109, 248, 225, 0.14)', '#6df8e1'),
    'db':  ('rgba(187, 51, 255, 0.16)',  '#bb33ff'),
    'aws': ('rgba(255, 195, 0, 0.14)',   '#ffc300'),
    'sec': ('rgba(255, 35, 35, 0.16)',   '#ff2323'),
    'bus': ('rgba(255, 119, 41, 0.16)',  '#ff7729'),
    'gen': ('rgba(154, 158, 167, 0.18)', '#9a9ea7'),
}
MUTED = '#b3b6bd'
_uid = [0]


def _extract(src, sid):
    m = re.search(r'<svg id="%s"([^>]*)>' % re.escape(sid), src)
    if not m:
        raise KeyError(sid)
    end = src.find('</svg>', m.end())
    body = src[m.end():end]
    vb = re.search(r'viewBox="([^"]+)"', m.group(1)).group(1)
    # make internal ids unique per use
    _uid[0] += 1
    ids = set(re.findall(r'id="([^"]+)"', body))
    for i in ids:
        body = body.replace('id="%s"' % i, 'id="%s-u%d"' % (i, _uid[0]))
        body = body.replace('url(#%s)' % i, 'url(#%s-u%d)' % (i, _uid[0]))
    return vb, body


def logo(name, x, y, s=12):
    vb, body = _extract(LOGOS, 'logo-' + name)
    return f'<svg x="{x}" y="{y}" width="{s}" height="{s}" viewBox="{vb}" fill="none" xmlns="http://www.w3.org/2000/svg">{body}</svg>'


def icon(name, x, y, color, s=12):
    vb, body = _extract(ICONS, 'icon-' + name)
    return f'<svg x="{x}" y="{y}" width="{s}" height="{s}" viewBox="{vb}" fill="none" color="{color}" xmlns="http://www.w3.org/2000/svg">{body}</svg>'


def esc(t):
    return html.escape(t, quote=False)


def text(x, y, t, size=8, color=MUTED, font='JetBrains Mono', weight=None, anchor='start', italic=False):
    w = f' font-weight="{weight}"' if weight else ''
    it = ' font-style="italic"' if italic else ''
    return f'<text x="{x}" y="{y}" fill="{color}" font-size="{size}" font-family="{font}"{w}{it} text-anchor="{anchor}">{esc(t)}</text>'


def box(x, y, w, h, kind, title, lines=(), logo_name=None, icon_name=None, dashed=False,
        tsize=11, lsize=8, align='middle', mask=True, title_y=None, line_gap=12):
    fill, stroke = K[kind]
    out = []
    if mask:
        out.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="4" fill="#282828"/>')
    da = ' stroke-dasharray="5,3"' if dashed else ''
    out.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="4" fill="{fill}" stroke="{stroke}" stroke-width="1.5"{da}/>')
    if logo_name:
        out.append(logo(logo_name, x + 8, y + 7))
    elif icon_name:
        out.append(icon(icon_name, x + 8, y + 7, stroke))
    if align == 'middle':
        cx, anchor = x + w / 2, 'middle'
    else:
        cx, anchor = x + (26 if (logo_name or icon_name) else 10), 'start'
    ty = title_y if title_y is not None else y + 18
    out.append(text(cx, ty, title, size=tsize, color='white', font='Inter', weight=600, anchor=anchor))
    ly = ty + 14
    for ln in lines:
        if isinstance(ln, tuple):
            t, opts = ln[0], ln[1]
        else:
            t, opts = ln, {}
        if t:
            out.append(text(cx, ly, t, size=opts.get('size', lsize), color=opts.get('color', MUTED),
                            font=opts.get('font', 'JetBrains Mono'), anchor=anchor, italic=opts.get('italic', False)))
        ly += opts.get('gap', line_gap)
    return '\n'.join(out)


def region(x, y, w, h, label, color='#faff69', dash='8,4', rx=12, fill='rgba(250, 255, 105, 0.03)', lsize=10, sub=None):
    out = [f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" fill="{fill}" stroke="{color}" stroke-width="1" stroke-dasharray="{dash}"/>',
           text(x + 12, y + 17, label, size=lsize, color=color, font='Inter', weight=600)]
    if sub:
        out.append(text(x + 12, y + 30, sub, size=8, color=MUTED))
    return '\n'.join(out)


def arrow(d, kind='gen', dashed=False, both=False, width=1.5):
    color = K[kind][1]
    da = ' stroke-dasharray="5,4"' if dashed else ''
    ms = f' marker-start="url(#arr-{kind})"' if both else ''
    if isinstance(d, (list, tuple)):
        d = 'M ' + ' L '.join(f'{a} {b}' for a, b in d)
    return f'<path d="{d}" fill="none" stroke="{color}" stroke-width="{width}"{da} marker-end="url(#arr-{kind})"{ms}/>'


def badge(cx, cy, t, kind='gen', size=8):
    fill, stroke = K[kind]
    w = len(t) * size * 0.61 + 12
    return (f'<rect x="{cx - w / 2:.1f}" y="{cy - 7}" width="{w:.1f}" height="14" rx="7" fill="#1f1f1c"/>'
            f'<rect x="{cx - w / 2:.1f}" y="{cy - 7}" width="{w:.1f}" height="14" rx="7" fill="{fill}"/>'
            + text(cx, cy + 3, t, size=size, color=stroke, anchor='middle'))


def defs():
    ms = ''.join(
        f'<marker id="arr-{k}" markerWidth="10" markerHeight="7" refX="9" refY="3.5" orient="auto-start-reverse">'
        f'<polygon points="0 0, 10 3.5, 0 7" fill="{v[1]}"/></marker>' for k, v in K.items())
    return (f'<defs>{ms}<pattern id="grid" width="40" height="40" patternUnits="userSpaceOnUse">'
            '<path d="M 40 0 L 0 0 0 40" fill="none" stroke="#323232" stroke-width="0.5"/></pattern></defs>'
            '<rect width="100%" height="100%" fill="url(#grid)"/>')


def legend(x, y, items):
    """items: list of (swatch, label) where swatch is kind, ('line', kind, dashed), ('bound', color)."""
    out = [text(x, y + 8, 'Legend', size=10, color='#faff69', font='Inter', weight=600)]
    cx = x + 58
    for sw, label in items:
        if isinstance(sw, str):
            f, s = K[sw]
            out.append(f'<rect x="{cx}" y="{y}" width="16" height="10" rx="2" fill="{f}" stroke="{s}" stroke-width="1"/>')
        elif sw[0] == 'dashbox':
            f, s = K[sw[1]]
            out.append(f'<rect x="{cx}" y="{y}" width="16" height="10" rx="2" fill="{f}" stroke="{s}" stroke-width="1" stroke-dasharray="3,2"/>')
        elif sw[0] == 'line':
            da = ' stroke-dasharray="3,3"' if sw[2] else ''
            out.append(f'<line x1="{cx}" y1="{y + 5}" x2="{cx + 16}" y2="{y + 5}" stroke="{K[sw[1]][1]}" stroke-width="1.5"{da}/>')
        elif sw[0] == 'bound':
            out.append(f'<rect x="{cx}" y="{y}" width="16" height="10" rx="2" fill="none" stroke="{sw[1]}" stroke-width="1" stroke-dasharray="3,2"/>')
        out.append(text(cx + 22, y + 8, label, size=8, font='Inter'))
        cx += 22 + len(label) * 4.6 + 22
    return '\n'.join(out)


def cards_html(cards):
    out = []
    for color, title, items, badges in cards:
        lis = '\n'.join(f'          <li>{i[0]}</li>' if isinstance(i, tuple) else f'          <li>• {i}</li>' for i in items)
        bd = ''
        if badges:
            bd = '\n        <div class="badges">' + ''.join(f'<span class="badge {color}">{esc(b)}</span>' for b in badges) + '</div>'
        out.append(f'''      <div class="card">
        <div class="card-header"><div class="card-dot {color}"></div><h3>{title}</h3></div>
        <ul>
{lis}
        </ul>{bd}
      </div>''')
    return '\n'.join(out)


NAV = [('overview.html', 'Overview'),
       ('aws-infrastructure.html', 'AWS infrastructure'),
       ('clickhouse-components.html', 'ClickHouse components'),
       ('deployment-pipeline.html', 'Deployment & airgap pipeline')]


def page(fname, title, subtitle, vw, vh, svg_body, cards, footer):
    s = TEMPLATE
    s = s.replace('<title>[PROJECT NAME] Architecture Diagram</title>', f'<title>{title}</title>')
    s = s.replace('<h1>[PROJECT NAME] Architecture</h1>', f'<h1>{title}</h1>')
    nav = ' · '.join((f'<strong>{n}</strong>' if f == fname else f'<a href="{f}">{n}</a>') for f, n in NAV)
    s = s.replace('<p class="subtitle">[Subtitle description]</p>',
                  f'<p class="subtitle">{subtitle}</p>\n      <p class="subtitle nav">Views: {nav}</p>')
    a = s.index('<svg viewBox="0 0 1000 680">')
    b = s.index('</svg>\n    </div>', a) + len('</svg>')
    s = s[:a] + f'<svg viewBox="0 0 {vw} {vh}" xmlns="http://www.w3.org/2000/svg">\n{defs()}\n{svg_body}\n      </svg>' + s[b:]
    a = s.index('<div class="cards">') + len('<div class="cards">')
    b = s.index('<!-- Footer -->')
    s = s[:a] + '\n' + cards_html(cards) + '\n    </div>\n\n    ' + s[b:]
    s = re.sub(r'<p class="footer">.*?</p>', f'<p class="footer">{footer}</p>', s, flags=re.S)
    s = s.replace("'diagram.png'", f"'{fname[:-5]}.png'").replace("'diagram.pdf'", f"'{fname[:-5]}.pdf'")
    s = s.replace('max-width: 1200px;', 'max-width: 1440px;')
    s = s.replace('</style>', '''    .ch-mark { min-width: 0; }
    .nav { margin-top: 0.35rem; font-size: 0.8rem; }
    .nav a { color: #00cbeb; text-decoration: none; }
    .nav a:hover { text-decoration: underline; }
    .nav strong { color: #faff69; font-weight: 600; }
  </style>''', 1)
    (OUT / fname).write_text(s)
    print('wrote', OUT / fname)


FOOTER = 'ch-gov · ClickHouse Private on AWS EKS · generated from ansible/group_vars/all.yml defaults (fips: false unless noted)'

# =====================================================================================
# 1. AWS infrastructure
# =====================================================================================
def aws_view():
    o = []
    # ---- boundaries first
    o.append(region(240, 30, 1105, 880, 'AWS account <YOUR_ACCOUNT_ID> · us-east-1 (target, profile sa)'))
    o.append(region(260, 165, 800, 725, 'VPC 10.20.0.0/16 · clickhouse-private-vpc', color='#ffc300', dash='6,3', rx=10,
                    fill='rgba(255, 195, 0, 0.02)'))
    azs = [('us-east-1a', 275, '10.20.192.0/20', '10.20.0.0/18'),
           ('us-east-1b', 537, '10.20.208.0/20', '10.20.64.0/18'),
           ('us-east-1c', 799, '10.20.224.0/20', '10.20.128.0/18')]
    AW = 246
    for name, x, pub, priv in azs:
        o.append(region(x, 210, AW, 668, name, color='#9a9ea7', dash='4,4', rx=8, fill='none', lsize=9))
        o.append(f'<rect x="{x + 8}" y="228" width="{AW - 16}" height="56" rx="6" fill="rgba(0, 203, 235, 0.05)" stroke="#00cbeb" stroke-width="1" stroke-dasharray="3,3"/>')
        o.append(text(x + 16, 242, 'public subnet ' + pub, size=8, color='#00cbeb'))
        o.append(f'<rect x="{x + 8}" y="296" width="{AW - 16}" height="572" rx="6" fill="rgba(109, 248, 225, 0.03)" stroke="#6df8e1" stroke-width="1" stroke-dasharray="3,3"/>')
        o.append(text(x + 16, 310, 'private subnet ' + priv, size=8, color='#6df8e1'))

    # ---- left column source account (boundary)
    o.append(region(15, 72, 205, 140, 'ClickHouse Inc. account', color='#9a9ea7', dash='4,4', rx=8, fill='none', lsize=9))

    # ---- arrows (behind boxes)
    # skopeo copy: source ECR -> target ECR
    o.append(arrow([(210, 132), (258, 110)], 'bus', width=1.8))
    o.append(badge(236, 150, 'skopeo', 'bus'))
    # workstation -> CFN / EKS / ECR mgmt
    o.append(arrow([(210, 280), (250, 280), (250, 56), (790, 56), (790, 70)], 'gen'))
    o.append(arrow([(580, 56), (580, 70)], 'gen'))
    o.append(badge(470, 56, 'cloudformation · helm · kubectl', 'gen'))
    # ECR -> IGW -> NAT (image pulls)
    o.append(arrow([(430, 144), (430, 160), (670, 160), (670, 174)], 'gen', dashed=True, both=True))
    o.append(arrow([(640, 202), (640, 206), (470, 206), (470, 240)], 'gen', dashed=True, both=True))
    o.append(badge(550, 160, 'image pulls (ECR API via NAT)', 'gen'))
    # clients -> NLB
    o.append(arrow([(210, 440), (250, 440), (250, 340), (283, 340)], 'fe'))
    # NLB -> server pods (one per AZ)
    for _, x, _, _ in azs:
        o.append(arrow([(x + 70, 353), (x + 70, 438)], 'fe'))
    o.append(badge(345, 395, ':8123 · :9000', 'fe'))
    # Langfuse NLB -> langfuse pods on operator nodes (AZ a)
    # server pods -> S3 GW endpoint
    o.append(arrow([(1023, 470), (1045, 470)], 'db'))
    o.append(arrow([(1132, 470), (1148, 470)], 'db'))
    o.append(badge(1100, 505, 'HTTPS · IRSA', 'db'))

    # ---- top-row regional services
    o.append(box(260, 72, 200, 70, 'aws', 'Target ECR (private)', [
        '<acct>.dkr.ecr.us-east-1…', ('fips: dkr-ecr-fips…on.aws', {'color': '#ffc300'}), 'images + OCI Helm charts'],
        logo_name='aws', align='start'))
    o.append(box(480, 72, 200, 82, 'aws', 'CloudFormation', [
        '-vpc · -eks · -nodegroups', '-irsa · -langfuse-irsa (opt.)', '-grafana-irsa (opt.)', 'one stack per infra step'],
        logo_name='aws', align='start'))
    o.append(box(700, 72, 190, 70, 'aws', 'EKS control plane', [
        'clickhouse-private-eks · 1.36', 'API: private + public endpoint', 'OIDC provider (IRSA)'],
        logo_name='kubernetes', align='start'))
    o.append(box(910, 72, 180, 70, 'sec', 'IAM roles', [
        'ClickHouseS3Role (IRSA)', 'EbsCsiDriverRole (IRSA)', 'EKS cluster + node roles'],
        icon_name='key', align='start'))
    o.append(box(1110, 72, 220, 70, 'sec', 'KMS keys', [
        'EKS secrets envelope key', 'CH bucket CMK · EBS CMK', 'Langfuse bucket CMK (opt.)'],
        icon_name='lock', align='start'))

    # ---- left column
    o.append(box(28, 100, 182, 100, 'aws', 'Source ECR', [
        '<SOURCE_ECR_ACCOUNT_ID> · us-east-1', 'clickhouse-server / keeper', 'clickhouse-operator · helm/*',
        ('read-only: profile private-us', {'color': '#ffc300'}), ('ClickHouseAirgapECRPullRole', {'color': '#ffc300'})],
        logo_name='aws', align='start', line_gap=11))
    o.append(box(15, 240, 195, 110, 'gen', 'Operator workstation', [
        'scripts/up.sh → ansible-playbook', 'aws · kubectl · helm · skopeo', '.aws/config (project-local)',
        'state/: kubeconfig, passwords,', '        TLS keys (gitignored)'],
        icon_name='console', align='start', line_gap=12))
    o.append(box(15, 410, 195, 62, 'fe', 'In-VPC / VPN clients', [
        'apps · BI · clickhouse-client', 'NLB is internal by default'], icon_name='users', align='start'))
    o.append(box(15, 510, 195, 82, 'gen', 'Public registries', [
        'registry.k8s.io (kube-rbac-proxy)', 'cgr.dev · docker.langfuse.com', '(Langfuse, opt.) — also skopeo',
        ('dhi.io (auth, opt.) — Grafana/awscli', {'color': '#ffc300'})],
        icon_name='globe', align='start'))

    # ---- IGW + NAT
    o.append(box(600, 176, 140, 24, 'aws', 'Internet Gateway', [], tsize=9, title_y=192))
    o.append(box(405, 242, 108, 34, 'aws', 'NAT gateway', ['nat_mode: single'], tsize=9, title_y=255, lsize=7, line_gap=10))
    for _, x, _, _ in azs[1:]:
        o.append(text(x + 16, 262, 'no NAT (single mode) — per-az', size=7))
        o.append(text(x + 16, 272, 'mode adds one here', size=7))

    # ---- NLBs spanning AZs
    o.append(box(283, 322, 770, 31, 'aws', 'Internal NLB · svc default-us-01-lb · cross-zone', [], tsize=10, title_y=335))
    o.append(text(668, 348, 'TCP 8123 (HTTP) · 9000 (native)  —  fips: 8443 (HTTPS) · 9440 (native TLS)', size=8, color='#ffc300', anchor='middle'))
    o.append(box(283, 362, 770, 24, 'aws', 'Langfuse NLB (opt.) · svc langfuse-lb · :80, or TLS terminated with an ACM cert', [],
                 tsize=9, title_y=378, dashed=True))
    o.append(box(283, 388, 770, 21, 'aws', 'Grafana NLB (opt.) · svc grafana-lb · :3000, or TLS terminated with an ACM cert', [],
                 tsize=9, title_y=402, dashed=True))

    # ---- nodes
    SC = '#6df8e1'
    for i, (name, x, _, _) in enumerate(azs):
        nx, nw = x + 16, AW - 32
        # server node
        o.append(box(nx, 410, nw, 124, 'aws', 'server node · m7gd.2xlarge', [
            'label clickhouseGroup=server-arm64 · tainted'], tsize=10, lsize=7, align='start', title_y=424))
        o.append(box(nx + 8, 440, 132, 84, 'db', 'clickhouse-server', [
            f'replica {i} · 26.2.1.525', '4 CPU · 16Gi', 'no PVC (stateless)', 'IRSA service acct'],
            logo_name='clickhouse', align='start', tsize=9, lsize=7, line_gap=11))
        o.append(box(nx + 146, 440, nw - 154, 84, 'gen', 'cache', [
            'local NVMe', '/nvme/disk', '300Gi', 'read cache'], tsize=9, lsize=7, line_gap=11, align='start'))
        # keeper node
        o.append(box(nx, 552, nw, 110, 'aws', 'keeper node · m7g.xlarge', [
            'label clickhouseGroup=keeper-arm64 · tainted'], tsize=10, lsize=7, align='start', title_y=566))
        o.append(box(nx + 8, 582, 132, 70, 'db', 'clickhouse-keeper', [
            f'keeper-{i} · 26.2.1.258', '2 CPU · 4Gi', 'Raft member'],
            logo_name='clickhouse', align='start', tsize=9, lsize=7, line_gap=11))
        o.append(box(nx + 146, 582, nw - 154, 70, 'aws', 'EBS gp3', [
            '10Gi PVC', 'encrypted', 'EBS CSI'], tsize=9, lsize=7, line_gap=11, align='start'))
        # operator node
        if i < 2:
            o.append(box(nx, 680, nw, 178, 'aws', 'operator node · m7i.xlarge', [
                'untainted · unlabelled · x86_64'], tsize=10, lsize=7, align='start', title_y=694))
            o.append(box(nx + 8, 714, nw - 16, 48, 'be', 'clickhouse-operator', [
                f'replica {i} of 2 (zone-spread)', '+ kube-rbac-proxy sidecar'], logo_name='clickhouse', align='start', tsize=9, lsize=7, line_gap=10))
            o.append(box(nx + 8, 768, nw - 16, 32, 'gen', 'cluster add-ons', [
                'CoreDNS · EBS CSI controller'], align='start', tsize=9, lsize=7, title_y=780))
            if i == 0:
                o.append(box(nx + 8, 806, nw - 16, 46, 'fe', 'Langfuse (opt.)', [
                    'web · worker · postgres · valkey', 'Chainguard PG/Valkey · EBS PVCs'],
                    align='start', tsize=9, lsize=7, dashed=True, line_gap=10))
            else:
                o.append(text(nx + 12, 820, 'Langfuse pods may schedule on', size=7))
                o.append(text(nx + 12, 831, 'either operator node', size=7))
        else:
            o.append(f'<rect x="{nx}" y="680" width="{nw}" height="178" rx="4" fill="none" stroke="#9a9ea7" stroke-width="1" stroke-dasharray="4,4"/>')
            o.append(text(nx + nw / 2, 760, 'operator node group', size=9, color=MUTED, font='Inter', anchor='middle'))
            o.append(text(nx + nw / 2, 774, 'min 2 · max 4 — ASG can', size=8, anchor='middle'))
            o.append(text(nx + nw / 2, 786, 'place a node in any AZ', size=8, anchor='middle'))

    # ---- S3 gateway endpoint + right column
    o.append(box(1048, 452, 84, 40, 'aws', 'S3 gateway', ['VPC endpoint'], tsize=9, lsize=7, title_y=467))
    o.append(box(1150, 420, 180, 110, 'aws', 'S3 · table data', [
        'clickhouse-private-', '  <acct>-us-east-1', 'prefix ch-s3-4f6a1d2e…', 'SharedMergeTree parts',
        ('fips: s3-fips endpoint, CMK', {'color': '#ffc300'})], logo_name='aws-s3', align='start', line_gap=12))
    o.append(box(1150, 560, 180, 66, 'aws', 'S3 · Langfuse (opt.)', [
        'langfuse-<acct>-us-east-1', 'events · exports · media'], logo_name='aws-s3', align='start', dashed=True))
    o.append(box(1150, 650, 180, 54, 'aws', 'ACM (opt.)', [
        'self-signed cert for', 'Langfuse NLB TLS'], align='start', dashed=True, line_gap=11))
    o.append(box(1150, 718, 180, 66, 'aws', 'S3 · Grafana plugins (opt.)', [
        'grafana-<acct>-us-east-1', 'grafana-clickhouse-datasource', 'zip, under plugins/ prefix'],
        logo_name='aws-s3', align='start', dashed=True, line_gap=11))
    o.append(box(1150, 180, 180, 80, 'gen', 'Where ClickHouse lives', [
        ('3 × server  → server nodes', {}), ('3 × keeper  → keeper nodes', {}), ('operator    → operator nodes', {}),
        ('data        → S3, never local', {})], align='start', tsize=10, lsize=7.5, line_gap=12))
    o.append(box(1150, 280, 180, 110, 'gen', 'fips: true changes', [
        'arm64 → x86_64 (m7i, m6id)', 'image tags gain -fips', 'ECR/S3/STS → FIPS endpoints',
        'native TLS on every CH port', 'RSA 3072 · KMS CMKs', 'Langfuse NLB forced to TLS'],
        align='start', tsize=10, lsize=7.5, line_gap=12, icon_name='lock'))

    o.append(legend(250, 925, [('aws', 'AWS service / EC2 node'), ('db', 'ClickHouse pod'), ('be', 'Operator'),
                               ('fe', 'Client / ingress'), ('sec', 'Identity & keys'), ('gen', 'Generic / storage'),
                               (('dashbox', 'gen'), 'Optional (langfuse.enabled)'), (('dashbox', 'aws'), 'Optional (grafana.enabled)'),
                               (('line', 'bus', False), 'Image mirror')]))

    cards = [
        ('sunrise', 'Compute & placement', [
            'Three managed node groups across 3 AZs: keeper (3 × m7g.xlarge), server (3–6 × m7gd.2xlarge), operator (2–4 × m7i.xlarge)',
            'Keeper and server groups carry the <code>clickhouse.com/do-not-schedule</code> taint; only ClickHouse pods tolerate it',
            'Server nodes bind instance-store NVMe to <code>/nvme/disk</code> at boot for the 300Gi read cache',
            'Operator group is untainted, so it also hosts CoreDNS, EBS CSI and (optionally) Langfuse',
        ], ['AL2023 arm64', 'fips → x86_64']),
        ('teal', 'Network', [
            'VPC 10.20.0.0/16: public /20s for NAT + IGW, private /18s for every node and NLB',
            'One NAT gateway by default (<code>nat_mode: single</code>); <code>per-az</code> adds one per zone',
            'S3 gateway endpoint keeps table-data traffic off NAT',
            'ClickHouse NLB is internal by default (none | internal | public, public needs allowed_cidrs)',
        ], ['8123 / 9000', 'fips: 8443 / 9440']),
        ('red', 'Storage, identity & keys', [
            'All table data in one S3 bucket under a per-cluster key prefix; server pods keep no PVC',
            'Keeper is the only stateful ClickHouse component: 3 × 10Gi gp3-encrypted EBS',
            'IRSA: server pods assume ClickHouseS3Role via the EKS OIDC provider, so no static keys exist',
            'KMS: EKS secrets envelope encryption; bucket and EBS CMKs',
        ], ['IRSA', 'KMS', 'gp3-encrypted']),
    ]
    page('aws-infrastructure.html', 'AWS Infrastructure',
         'Everything <code>scripts/up.sh</code> provisions in the target account, and which ClickHouse components run on which nodes',
         1360, 950, '\n'.join(o), cards, FOOTER)


# =====================================================================================
# 2. ClickHouse components
# =====================================================================================
def ch_view():
    o = []
    # boundaries
    o.append(region(480, 60, 640, 555, 'namespace ns-default-us-01', color='#bb33ff', dash='6,3', rx=10,
                    fill='rgba(187, 51, 255, 0.03)', sub='ClickHouseCluster c-default-us-01 · Helm release default-us-01 (onprem-clickhouse-cluster 1.8.7)'))
    o.append(region(480, 655, 640, 125, 'namespace clickhouse-operator-system', color='#6df8e1', dash='6,3', rx=10,
                    fill='rgba(109, 248, 225, 0.03)'))
    o.append(region(15, 820, 1105, 170, 'namespace langfuse  (optional · langfuse.enabled)', color='#00cbeb', dash='6,3', rx=10,
                    fill='rgba(0, 203, 235, 0.03)'))
    o.append(region(15, 1010, 1105, 170, 'namespace grafana  (optional · grafana.enabled)', color='#f46800', dash='6,3', rx=10,
                    fill='rgba(244, 104, 0, 0.03)'))

    SX = [510, 715, 920]  # server/keeper columns
    SW = 175
    # ---- arrows first
    # native / http clients -> NLB
    o.append(arrow([(230, 128), (260, 128), (260, 165), (288, 165)], 'fe'))
    o.append(arrow([(230, 208), (260, 208), (260, 185), (288, 185)], 'fe'))
    # NLB -> servers
    o.append(arrow([(440, 175), (508, 175)], 'fe'))
    # svc -> servers
    o.append(arrow([(440, 320), (495, 320), (495, 200), (508, 200)], 'be'))
    # ch-client -> k8s API (port-forward)
    o.append(arrow([(230, 298), (250, 298), (250, 690), (288, 690)], 'gen', dashed=True))
    o.append(badge(250, 470, 'port-forward', 'gen'))
    # ansible -> API
    o.append(arrow([(230, 725), (288, 725)], 'gen'))
    # operator <-> API
    o.append(arrow([(440, 712), (508, 712)], 'be', both=True))
    # operator -> reconciles namespace
    o.append(arrow([(640, 675), (640, 617)], 'be'))
    o.append(badge(640, 636, 'reconciles STS · Svc · ConfigMaps · PVCs', 'be'))
    # servers -> keeper bus, bus -> keepers
    for x in SX:
        o.append(arrow([(x + 60, 262), (x + 60, 300)], 'bus', both=True))
        o.append(arrow([(x + 60, 322), (x + 60, 360)], 'bus', both=True))
    # keeper raft
    o.append(arrow([(SX[0] + SW, 400), (SX[1] - 2, 400)], 'bus', dashed=True, both=True))
    o.append(arrow([(SX[1] + SW, 400), (SX[2] - 2, 400)], 'bus', dashed=True, both=True))
    o.append(arrow([(SX[0] + 90, 444), (SX[0] + 90, 456), (SX[2] + 90, 456), (SX[2] + 90, 444)], 'bus', dashed=True, both=True))
    o.append(badge(SX[1] + 87, 456, 'Raft · quorum 2 of 3', 'bus'))
    # servers -> S3
    o.append(arrow([(1097, 175), (1148, 175)], 'db', width=2))
    o.append(badge(1123, 160, 'HTTPS', 'db'))
    # SA -> STS
    o.append(arrow([(690, 560), (705, 560), (705, 588), (1240, 588), (1240, 372)], 'sec', dashed=True))
    o.append(badge(1000, 588, 'projected token → AssumeRoleWithWebIdentity', 'sec'))
    o.append(arrow([(1240, 300), (1240, 262)], 'sec', dashed=True))
    o.append(badge(1273, 282, 'temp creds', 'sec'))
    # keeper -> EBS
    o.append(arrow([(SX[2] + SW, 420), (1148, 420)], 'aws'))
    # S3 -> KMS
    # langfuse arrows
    o.append(arrow([(330, 866), (330, 845), (462, 845), (462, 330), (442, 330)], 'fe', width=1.8))
    o.append(f'<path d="M 557 866 L 557 845 L 462 845" fill="none" stroke="#00cbeb" stroke-width="1.8"/>')
    o.append(badge(462, 800, 'HTTP :8123 runtime · native :9000 migrations', 'fe'))
    o.append(arrow([(200, 908), (238, 908)], 'fe'))
    o.append(f'<path d="M 330 950 L 330 972 L 1245 972" fill="none" stroke="#00cbeb" stroke-width="1.5"/>')
    o.append(f'<path d="M 557 950 L 557 972" fill="none" stroke="#00cbeb" stroke-width="1.5"/>')
    o.append(arrow([(765, 972), (765, 940)], 'fe'))
    o.append(arrow([(940, 972), (940, 940)], 'fe'))
    o.append(arrow([(1245, 972), (1245, 950)], 'fe'))
    o.append(badge(1090, 972, 'web + worker → Postgres · Valkey · S3 (IRSA)', 'fe'))

    # ---- left: clients
    o.append(box(20, 100, 210, 56, 'fe', 'clickhouse-client · drivers', [
        'native TCP :9000', ('fips: :9440 --secure', {'color': '#ffc300'})], icon_name='console', align='start'))
    o.append(box(20, 180, 210, 56, 'fe', 'HTTP · JDBC/ODBC · BI', [
        'HTTP :8123', ('fips: HTTPS :8443', {'color': '#ffc300'})], icon_name='http', align='start'))
    o.append(box(20, 270, 210, 56, 'gen', 'scripts/ch-client.sh', [
        'kubectl port-forward to a pod', 'no load balancer needed'], icon_name='console', align='start'))
    o.append(box(20, 700, 210, 56, 'gen', 'Ansible (up.sh)', [
        'helm install operator + cluster', 'kubernetes.core.k8s'], icon_name='console', align='start'))

    # ---- entry points
    o.append(box(290, 145, 150, 62, 'aws', 'NLB', ['default-us-01-lb', 'internal · cross-zone', 'none|internal|public'],
                 logo_name='aws', align='start', line_gap=11))
    o.append(box(290, 290, 150, 62, 'be', 'Service', ['c-default-us-01-', '  server-any', 'ClusterIP · round-robin'],
                 logo_name='kubernetes', align='start', line_gap=11))
    o.append(box(290, 680, 150, 60, 'aws', 'Kubernetes API', ['EKS control plane', 'CR + objects in etcd'],
                 logo_name='kubernetes', align='start'))

    # ---- servers
    for i, x in enumerate(SX):
        o.append(box(x, 118, SW, 144, 'db', f'server replica {i}', [
            'c-default-us-01-server-<id>', 'StatefulSet × 1 pod · no PVC', 'clickhouse-server 26.2.1.525',
            'SharedMergeTree engine', ('NVMe cache 300Gi (hostPath)', {'color': '#9a9ea7'}),
            ('users/grants: in Keeper', {'color': '#9a9ea7'}), ('fips: openSSL.required', {'color': '#ffc300'})],
            logo_name='clickhouse', align='start', line_gap=12))
    # keeper bus
    o.append(f'<rect x="510" y="300" width="585" height="22" rx="4" fill="#282828"/>')
    o.append(f'<rect x="510" y="300" width="585" height="22" rx="4" fill="rgba(255, 119, 41, 0.16)" stroke="#ff7729" stroke-width="1"/>')
    o.append(text(802, 314, 'Keeper client protocol — part registry · replication log · DDL queue · locks · users & grants', size=8, color='#ff7729', anchor='middle'))
    o.append(text(802, 477, 'Replicas never copy parts to each other: each reads the same parts from S3; Keeper says which exist', size=7.5, color=MUTED, anchor='middle', italic=True))
    # keepers
    for i, x in enumerate(SX):
        o.append(box(x, 360, SW, 82, 'db', f'keeper-{i}', [
            'STS c-default-us-01-keeper', 'clickhouse-keeper 26.2.1.258', 'PVC 10Gi gp3-encrypted',
            ('OnDelete update strategy', {'color': '#9a9ea7'})], logo_name='clickhouse', align='start', line_gap=12))
    # SA / secrets row
    o.append(box(510, 490, 180, 90, 'sec', 'ServiceAccount', [
        'ch-default-us-01-sa', 'annotation eks.amazonaws.com/', '  role-arn → ClickHouseS3Role', 'used by server pods'],
        icon_name='key', align='start', line_gap=11))
    o.append(box(715, 490, 175, 70, 'sec', 'TLS Secret (fips)', [
        'default-us-01-server-', '  cert-secret', 'CA + leaf, CA-chain verify'], icon_name='lock', align='start', line_gap=11))
    o.append(box(920, 490, 175, 70, 'sec', 'Accounts', [
        'default (admin, sha256)', 'prometheus (metrics user)', 'pw in state/ (gitignored)'], icon_name='users', align='start', line_gap=11))

    # ---- operator
    o.append(box(510, 685, 260, 80, 'be', 'clickhouse-operator', [
        'main-1.20441.1 · 2 replicas (zone-spread)', '+ kube-rbac-proxy sidecar', 'webhooks disabled (tutorial)',
        'image base path → target ECR'], logo_name='clickhouse', align='start', line_gap=11))
    o.append(box(790, 685, 305, 80, 'gen', 'What it manages', [
        'watches ClickHouseCluster CRs', 'creates keeper + per-replica server STS', 'Services, ConfigMaps, PVCs, debug/init pods',
        'repairs drift continuously'], align='start', line_gap=11))

    # ---- right column
    o.append(box(1150, 118, 190, 144, 'aws', 'S3 bucket', [
        'clickhouse-private-', '  <acct>-us-east-1', 'prefix ch-s3-4f6a1d2e…', 'every byte of every table',
        'sharded by short hash', ('fips: s3-fips endpoint,', {'color': '#ffc300'}), ('  SSE-KMS CMK', {'color': '#ffc300'})],
        logo_name='aws-s3', align='start', line_gap=12))
    o.append(box(1150, 300, 190, 72, 'sec', 'STS + IAM', [
        'AssumeRoleWithWebIdentity', 'ClickHouseS3Role', 'scoped to one bucket ARN'], icon_name='key', align='start', line_gap=11))
    o.append(box(1150, 390, 190, 64, 'aws', 'EBS volumes', [
        '3 × 10Gi gp3-encrypted', 'via EBS CSI (IRSA role)'], icon_name='disk', align='start'))
    o.append(box(1150, 480, 190, 80, 'gen', 'Ports at a glance', [
        'HTTP     8123 → fips 8443', 'native   9000 → fips 9440', 'fips zeroes the plaintext', 'ports for every caller'],
        align='start', line_gap=12, tsize=10))

    # ---- langfuse
    o.append(box(30, 878, 170, 60, 'aws', 'Langfuse NLB', ['svc langfuse-lb · :80', 'TLS via ACM when enabled'],
                 logo_name='aws', align='start', dashed=True))
    o.append(box(240, 868, 180, 82, 'fe', 'langfuse-web', ['langfuse 4.25.0 · :3000', 'NextAuth UI + API', 'reads traces from CH'],
                 icon_name='globe', align='start', dashed=True))
    o.append(box(454, 868, 206, 82, 'be', 'langfuse-worker', ['async ingest → ClickHouse', 'db langfuse · user langfuse',
                 ('fips: https 8443 / 9440 TLS', {'color': '#ffc300'})], icon_name='server', align='start', dashed=True))
    o.append(box(700, 878, 130, 60, 'db', 'PostgreSQL', ['chainguard/postgres', 'EBS PVC 20Gi'],
                 logo_name='postgres', align='start', dashed=True))
    o.append(box(840, 878, 190, 60, 'bus', 'Valkey', ['chainguard/valkey', 'queue + cache · PVC 8Gi'],
                 icon_name='share-network', align='start', dashed=True))
    o.append(box(1150, 878, 190, 70, 'aws', 'S3 · Langfuse bucket', ['events · exports · media', 'IRSA LangfuseS3Role'],
                 logo_name='aws-s3', align='start', dashed=True))

    # ---- grafana
    o.append(arrow([(200, 1098), (238, 1098)], 'fe'))
    o.append(arrow([(430, 1099), (450, 1099)], 'gen'))
    o.append(arrow([(670, 1099), (690, 1099)], 'sec'))
    o.append(arrow([(900, 1099), (1148, 1101)], 'sec', dashed=True))
    o.append(badge(1024, 1085, 'IRSA · s3:GetObject plugins/*', 'sec'))
    o.append(box(30, 1068, 170, 60, 'aws', 'Grafana NLB', ['svc grafana-lb · :3000', 'TLS via ACM when enabled'],
                 logo_name='aws', align='start', dashed=True))
    o.append(box(240, 1058, 190, 82, 'fe', 'grafana', ['grafana chart · :3000', 'datasource uid clickhouse',
                 'user grafana (SELECT *.*)', 'no PVC (config-as-code)'], icon_name='globe', align='start', dashed=True,
                 tsize=9, lsize=7, line_gap=11))
    o.append(box(450, 1058, 220, 82, 'gen', 'initContainers: load-plugin', ['awscli + grafana image', 'fetch grafana-clickhouse-',
                 '  datasource from S3', 'before grafana starts'], icon_name='server', align='start', dashed=True,
                 tsize=9, lsize=7, line_gap=11))
    o.append(box(690, 1058, 210, 82, 'sec', 'ServiceAccount', ['grafana (release name)', 'role-arn → GrafanaS3Role',
                 's3:GetObject plugins/* only'], icon_name='key', align='start', dashed=True, tsize=9, lsize=7, line_gap=11))
    o.append(box(1150, 1068, 190, 70, 'aws', 'S3 · Grafana plugins', ['grafana-<acct>-us-east-1', 'IRSA-read, plugins/ prefix'],
                 logo_name='aws-s3', align='start', dashed=True))

    o.append(legend(20, 1200, [('db', 'ClickHouse server / keeper'), ('be', 'Operator / k8s object'), ('fe', 'Client / app'),
                                ('aws', 'AWS service'), ('sec', 'Identity & secrets'), (('line', 'bus', True), 'Keeper / Raft'),
                                (('line', 'sec', True), 'IRSA credential flow'), (('dashbox', 'fe'), 'Optional (Langfuse)'),
                                (('dashbox', 'aws'), 'Optional (Grafana)')]))

    cards = [
        ('violet', 'Data path', [
            'Any server takes any query; the NLB and <code>server-any</code> Service round-robin across all three',
            'Inserts write parts to S3 and register them in Keeper; other replicas see them within a second or two',
            'Reads hit the local NVMe cache first, then S3; losing a server pod loses nothing',
            'Keeper is the only stateful ClickHouse component and needs 2 of 3 up for writes',
        ], ['SharedMergeTree', 'stateless servers']),
        ('teal', 'Control path', [
            'Ansible installs two Helm charts: the operator, then the cluster (which renders the CR)',
            'The operator watches the CR and builds the keeper StatefulSet plus one StatefulSet per server replica',
            'Keeper uses <code>OnDelete</code> updates, so the cluster role restarts its pods itself',
            'Release name <code>default-us-01</code> fixes the SA name the IRSA trust policy expects',
        ], ['operator 1.20441.1', 'chart 1.8.7']),
        ('sunrise', 'FIPS differences (fips: true)', [
            '<code>server.openSSL.required</code> and <code>keeper.openSSL.required</code> are on, with a self-signed CA and leaf in one Secret',
            'Plaintext 8123/9000 go away for everyone: LB, ch-client and Langfuse all move to 8443/9440',
            'The in-pod S3 client uses the <code>s3-fips</code> endpoint and the bucket uses a KMS CMK',
            'Verification is CA-chain only, not mutual TLS',
        ], ['8443', '9440', 'RSA 3072']),
    ]
    page('clickhouse-components.html', 'ClickHouse Components',
         'How the ClickHouse Private parts connect: clients, servers, Keeper, S3, the operator, and the optional Langfuse/Grafana tenants',
         1360, 1240, '\n'.join(o), cards, FOOTER)


# =====================================================================================
# 3. Deployment pipeline
# =====================================================================================
def deploy_view():
    o = []
    o.append(region(15, 60, 1330, 490, 'scripts/up.sh → ansible-playbook deploy.yml  (every step idempotent · resume with --from <tag>)'))
    steps1 = [
        ('1–2', 'Images', 'ecr_setup · image_sync', ['tags: images', 'ECR repos + skopeo copy', 'server/keeper/operator', '+ 3 Helm charts'], 'bus'),
        ('3', 'VPC', 'vpc', ['tags: vpc', 'stack -vpc', '3 AZ · NAT · S3 GW'], 'aws'),
        ('4', 'EKS', 'eks_cluster', ['tags: eks', 'stack -eks', 'control plane · OIDC', 'KMS secrets key'], 'aws'),
        ('5', 'Node groups', 'eks_nodegroups', ['tags: nodes', 'stack -nodegroups', 'keeper · server · operator', 'NVMe launch template'], 'aws'),
        ('6', 'S3 + IRSA', 'storage_iam', ['tags: storage', 'stack -irsa', 'bucket · CH/EBS roles', 'KMS CMKs'], 'sec'),
        ('7', 'K8s prereqs', 'k8s_prereqs', ['tags: prereqs', 'snapshot CRDs', 'EBS CSI add-on', 'gp3-encrypted class'], 'be'),
    ]
    steps2 = [
        ('8', 'Operator', 'clickhouse_operator', ['tags: operator', 'helm: clickhouse-', '  operator-helm', 'webhooks off'], 'be'),
        ('9', 'Cluster', 'clickhouse_cluster', ['tags: cluster', 'helm: onprem-', '  clickhouse-cluster', 'passwords · TLS (fips)'], 'db'),
        ('10', 'Preflight', 'clickhouse_preflight', ['tags: preflight', 'kubectl preflight', 'node size · cache', 'storage class'], 'gen'),
        ('11', 'Verify', 'clickhouse_verify', ['tags: verify', 'write on replica A', 'read on replica B'], 'gen'),
        ('12', 'Load balancer', 'clickhouse_loadbalancer', ['tags: lb', 'svc default-us-01-lb', 'none|internal|public', 'probe via NLB'], 'fe'),
        ('13–15', 'Langfuse (opt.)', 'langfuse_* (3 roles)', ['tags: langfuse', 'stack -langfuse-irsa', 'CH db + user', 'helm langfuse 2.1.0'], 'fe'),
    ]
    steps3 = [
        ('16–18', 'Grafana (opt.)', 'grafana_* (3 roles)', ['tags: grafana', 'stack -grafana-irsa', 'CH user · plugin mirror', 'helm grafana (DHI images)'], 'fe'),
    ]
    BW, GAP, X0 = 196, 22, 35
    rows = [(steps1, 100), (steps2, 260), (steps3, 420)]
    for row, (steps, y) in enumerate(rows):
        for j, (num, name, role, lines, kind) in enumerate(steps):
            x = X0 + j * (BW + GAP)
            if j < len(steps) - 1:
                o.append(arrow([(x + BW, y + 50), (x + BW + GAP - 2, y + 50)], 'gen'))
            o.append(box(x, y, BW, 110, kind, f'{num} · {name}', [(role, {'color': 'white', 'size': 7.5})] + lines,
                         align='start', dashed=(num in ('13–15', '16–18')), line_gap=13))
        if row < len(rows) - 1:
            xe = X0 + (len(steps) - 1) * (BW + GAP) + BW / 2
            ny = rows[row + 1][1]
            o.append(arrow([(xe, y + 110), (xe, y + 135), (X0 + BW / 2, y + 135), (X0 + BW / 2, ny - 2)], 'gen'))
    o.append(text(X0 + 3 * (BW + GAP) + BW / 2, 228, 'Steps 1–12 follow ClickHouse\'s deploy-aws tutorial one-to-one', size=8, anchor='middle', italic=True))
    o.append(text(X0 + 3 * (BW + GAP) + BW / 2, 400, 'Steps 16–18 are optional (grafana.enabled), same pattern as Langfuse', size=8, anchor='middle', italic=True))

    # ---- supply chain
    o.append(region(15, 580, 830, 250, 'Airgap supply chain — the one hop across accounts', color='#ff7729', dash='6,3', rx=10,
                    fill='rgba(255, 119, 41, 0.03)'))
    o.append(arrow([(225, 665), (318, 665)], 'bus', width=1.8))
    o.append(arrow([(225, 760), (318, 720)], 'bus', width=1.8, dashed=True))
    o.append(arrow([(530, 690), (598, 690)], 'bus', width=1.8))
    o.append(arrow([(705, 740), (705, 772)], 'gen'))
    o.append(badge(270, 650, 'read', 'bus'))
    o.append(badge(564, 675, 'write', 'bus'))
    o.append(box(30, 620, 195, 90, 'aws', 'Source ECR', ['ClickHouse <SOURCE_ECR_ACCOUNT_ID>', 'profile private-us (SSO)', 'ClickHouseAirgapECR-', '  PullRole · read-only'],
                 logo_name='aws', align='start', line_gap=12))
    o.append(box(30, 730, 195, 84, 'gen', 'Public registries', ['registry.k8s.io', 'cgr.dev · docker.langfuse.com', 'langfuse charts (helm-http)',
                 ('dhi.io (auth) — Grafana/awscli', {'color': '#ffc300'})],
                 icon_name='globe', align='start', line_gap=12))
    o.append(box(320, 630, 210, 120, 'gen', 'skopeo on workstation', ['state/skopeo-auth.json', '  (short-lived tokens)', 'container images → ECR',
                 'Helm charts as OCI artifacts', 'tag gains -fips when fips', '--tags images to rerun'], icon_name='console', align='start', line_gap=13))
    o.append(box(600, 630, 210, 110, 'aws', 'Target ECR', ['<YOUR_ACCOUNT_ID> · us-east-1', 'clickhouse-server|keeper|', '  operator · kube-rbac-proxy',
                 'helm/* charts', ('fips: dkr-ecr-fips…on.aws', {'color': '#ffc300'})], logo_name='aws', align='start', line_gap=12))
    o.append(box(600, 774, 210, 44, 'be', 'EKS nodes pull only from here', ['no route to ClickHouse after install'], align='start', tsize=9, lsize=7.5))

    # ---- teardown
    o.append(region(870, 580, 475, 290, 'scripts/down.sh — teardown is not the reverse of bring-up', color='#ff2323', dash='6,3', rx=10,
                    fill='rgba(255, 35, 35, 0.03)'))
    td = [('lf-app', 'Langfuse first: its tables + PVCs need CH, operator, CSI'),
          ('gf-app', 'Grafana next (opt.): release+NLB, then CH user; --all also deletes its plugin bucket + IRSA'),
          ('lb', 'NLB before EKS, or it is orphaned and blocks VPC delete'),
          ('cluster', 'while nodes still run: operator + CSI clean up Keeper PVCs'),
          ('nodes', 'default mode stops here (~$0.15/hr floor)'),
          ('--all', 'operator · prereqs · storage · eks · vpc'),
          ('kept', 'S3 buckets (data) and ECR images — never deleted')]
    for k, (tag, why) in enumerate(td):
        y = 612 + k * 35
        kind = 'sec' if tag != 'kept' else 'aws'
        if k < len(td) - 1:
            o.append(arrow([(930, y + 20), (930, y + 34)], 'sec'))
        o.append(box(885, y, 90, 20, kind, tag, [], tsize=9, title_y=y + 14))
        o.append(text(985, y + 14, why, size=8))

    # ---- state
    o.append(box(15, 890, 1330, 50, 'gen', 'state/  (gitignored, back it up)', [
        'kubeconfig · clickhouse-admin-password · clickhouse-prometheus-password · clickhouse-tls-{ca,cert,key}.pem · preflight/ · skopeo-auth.json · langfuse-* secrets · grafana-admin-password · grafana-clickhouse-password'],
        align='start', icon_name='folder-closed', tsize=10, lsize=8))

    o.append(legend(20, 960, [('aws', 'CloudFormation stack'), ('be', 'K8s / Helm (operator)'), ('db', 'Helm (cluster)'),
                               ('gen', 'Check / tooling'), ('bus', 'Image mirror'), ('sec', 'IAM / teardown'),
                               (('dashbox', 'fe'), 'Optional (Langfuse)'), (('dashbox', 'aws'), 'Optional (Grafana)')]))
    cards = [
        ('orange', 'Airgap', [
            'The only cross-account traffic is Step 2: skopeo reads ClickHouse\'s ECR and writes yours',
            'Third-party images (kube-rbac-proxy, Chainguard Postgres/Valkey, Langfuse, Grafana/awscli via dhi.io) are mirrored the same way',
            'The operator\'s image base path is overridden, so the debug/init pods it generates also pull from your ECR',
        ], ['skopeo', 'OCI charts']),
        ('sunrise', 'Where state lives', [
            'AWS infrastructure: one CloudFormation stack per infra step (vpc, eks, nodegroups, irsa, langfuse-irsa, grafana-irsa)',
            'Kubernetes: Helm releases (operator, cluster, langfuse, grafana), the preflight chart via <code>helm template</code>, plus direct objects (StorageClass, LB Service, Secrets)',
            'Local: <code>state/</code> holds every generated secret; lose it and you lose the admin password',
        ], ['6 stacks', '4 Helm releases']),
        ('red', 'Cost meter', [
            'Everything up: about $2.34/hr (8 EC2 nodes, EKS, NAT)',
            '<code>down.sh</code>: about $0.15/hr, the EKS control plane plus NAT; back in ~15 min with <code>up.sh --from nodes</code>',
            '<code>down.sh --all</code>: about $0, leaving only S3 data and ECR images',
        ], ['up.sh', 'down.sh', '--nodes-only']),
    ]
    page('deployment-pipeline.html', 'Deployment Pipeline',
         'How <code>up.sh</code> builds the stack step by step, the airgap image hop, and the teardown order <code>down.sh</code> enforces',
         1360, 990, '\n'.join(o), cards, FOOTER)


def overview_view():
    o = []
    COLS = [245, 435, 625]
    CW = 150
    GX, GW = 232, 556          # server / keeper group boxes
    # service boundaries
    o.append(region(30, 120, 780, 335, 'Amazon EKS', color='#ffc300', dash='8,4', rx=12, fill='rgba(255, 195, 0, 0.03)'))
    o.append(region(235, 490, 575, 110, 'Amazon EBS', color='#ffc300', dash='8,4', rx=12, fill='rgba(255, 195, 0, 0.03)'))
    o.append(region(850, 120, 300, 335, 'Amazon S3', color='#ffc300', dash='8,4', rx=12, fill='rgba(255, 195, 0, 0.03)'))
    # component groups
    o.append(region(GX, 148, GW, 130, 'ClickHouse servers', color='#bb33ff', dash='5,3', rx=8,
                    fill='rgba(187, 51, 255, 0.04)', lsize=9))
    o.append(region(GX, 313, GW, 124, 'ClickHouse Keeper', color='#bb33ff', dash='5,3', rx=8,
                    fill='rgba(187, 51, 255, 0.04)', lsize=9))

    # arrows first
    o.append(arrow([(255, 64), (398, 64)], 'fe'))
    o.append(arrow([(COLS[1] + CW / 2, 88), (COLS[1] + CW / 2, 146)], 'fe'))
    o.append(badge(COLS[1] + CW / 2, 106, 'HTTPS :: TCP', 'fe'))
    for x in COLS:
        o.append(arrow([(x + 110, 262), (x + 110, 338)], 'bus', both=True))
        o.append(arrow([(x + 110, 410), (x + 110, 523)], 'gen'))
    o.append(badge(COLS[1] + 110, 296, 'metadata & coordination', 'bus'))
    o.append(arrow([(COLS[0] + CW, 375), (COLS[1] - 2, 375)], 'bus', dashed=True, both=True))
    o.append(arrow([(COLS[1] + CW, 375), (COLS[2] - 2, 375)], 'bus', dashed=True, both=True))
    o.append(arrow([(GX + GW, 213), (873, 213)], 'db', width=1.8, both=True))
    o.append(badge(830, 197, 'read / write', 'db'))
    o.append(arrow([(215, 213), (GX - 2, 213)], 'be'))
    o.append(arrow([(215, 375), (GX - 2, 375)], 'be'))
    o.append(badge(COLS[1] + 110, 472, 'one volume per Keeper', 'gen'))

    # clients + NLB
    o.append(box(55, 40, 200, 48, 'fe', 'Clients', ['BI :: CLI :: API :: MCP'], icon_name='users', align='start'))
    o.append(box(400, 40, 320, 48, 'aws', 'Network Load Balancer', ['Internal :: One address for all three servers'],
                 logo_name='aws', align='start'))

    # EKS contents
    o.append(box(55, 150, 160, 285, 'be', 'Operator', [
        'Reads the ClickHouseCluster', 'spec and creates, repairs, ', 'and scales the servers ', 'and Keeper'],
        logo_name='clickhouse', align='start', line_gap=13))
    for i, x in enumerate(COLS):
        o.append(box(x, 172, CW, 90, 'db', f'Server replica {i}', [
            '', 'Runs SQL queries', 'Local NVMe read cache'],
            logo_name='clickhouse', align='start', line_gap=13))
        o.append(box(x, 340, CW, 70, 'db', f'Keeper {i}', [
            '', 'Cluster metadata', 'Raft member'], logo_name='clickhouse', align='start', line_gap=13))
        o.append(box(x, 525, CW, 55, 'aws', f'Keeper {i} volume', ['Raft log + snapshots', 'ENCRYPTED'],
                     icon_name='disk', align='start'))
    o.append(text(GX + 12, 429, 'quorum: 2 of 3 up', size=8, color='#bb33ff', italic=True))

    # S3 contents
    o.append(box(875, 180, 250, 90, 'db', 'Table data', [
        'every table\'s data parts', '(SharedMergeTree)', '', 'ENCRYPTED'], logo_name='aws-s3', align='start', line_gap=13))
    o.append(text(1000, 305, 'All three servers share this', size=8, anchor='middle', italic=True))
    o.append(text(1000, 318, 'one copy. They never copy', size=8, anchor='middle', italic=True))
    o.append(text(1000, 331, 'data to each other.', size=8, anchor='middle', italic=True))

    o.append(legend(30, 625, [('db', 'ClickHouse component'), ('be', 'Operator'), ('aws', 'AWS resource'), ('fe', 'Client'),
                               (('line', 'fe', False), 'Queries'), (('line', 'db', False), 'Table data'),
                               (('line', 'bus', False), 'Keeper traffic'), (('line', 'bus', True), 'Raft between Keepers')]))
    cards = [
        ('sunrise', 'EKS', [
            'Every ClickHouse process runs as a container in a pod on the EKS cluster',
            'Three server pods answer queries; any of them can take any query',
            'Three Keeper pods hold the cluster metadata; the operator builds and repairs all six',
        ], None),
        ('sunrise', 'EBS', [
            'Keeper is the only ClickHouse component with a persistent disk',
            'One small encrypted gp3 volume per Keeper pod, attached through the EBS CSI driver',
        ], None),
        ('violet', 'S3', [
            'All table data lives in one S3 bucket',
            'Server pods are stateless: delete one and its replacement carries on from S3 and Keeper',
        ], None),
    ]
    page('overview.html', 'ClickHouse on AWS',
         'Where each ClickHouse component lives across EKS, EBS and S3',
         1180, 650, '\n'.join(o), cards, 'ch-gov · ClickHouse Private on AWS EKS')


OUT.mkdir(parents=True, exist_ok=True)
overview_view()
aws_view()
ch_view()
deploy_view()
