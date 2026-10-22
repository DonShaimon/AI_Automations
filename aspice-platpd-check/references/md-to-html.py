#!/usr/bin/env python3
"""Python port of md-to-html.ps1 (aspice-platpd-check skill) for hosts without PowerShell.

Converts an ASPICE PLATPD check report (Markdown) into a self-contained HTML report,
auto-linking Polarion work-item IDs and color-coding verdict cells.

Usage:
  python3 md-to-html.py --input reports/PLATPD-999-ASPICE-report.md [--output out.html]
"""
import argparse
import html as htmllib
import os
import re

DEFAULT_PROJECT_MAP = {
    "EPGSW": "app_software",
    "VWMS": "VW_MaaS",
    "PAOB": "Porsche_Audi_One_Box",
}
BASE_URL = "https://polarion.mobileye.com/polarion/redirect/project"

STYLE = """
<style>
  body { font-family: Segoe UI, Arial, sans-serif; max-width: 1200px; margin: 2em auto; padding: 0 1em; color: #1a1a1a; line-height: 1.5; }
  h1 { border-bottom: 3px solid #2b6cb0; padding-bottom: 0.3em; }
  h2 { border-bottom: 1px solid #ccc; padding-bottom: 0.2em; margin-top: 2em; color: #2b6cb0; }
  h3 { margin-top: 1.6em; color: #1a4971; }
  table { border-collapse: collapse; width: 100%; margin: 0.8em 0 1.2em 0; font-size: 0.92em; }
  th, td { border: 1px solid #ccc; padding: 6px 10px; text-align: left; vertical-align: top; }
  th { background: #2b6cb0; color: #fff; }
  tr:nth-child(even) td { background: #f7f9fb; }
  a { color: #2b6cb0; text-decoration: none; }
  a:hover { text-decoration: underline; }
  code { background: #eef1f4; padding: 1px 5px; border-radius: 3px; font-family: Consolas, monospace; }
  hr { border: none; border-top: 1px solid #ddd; margin: 1.5em 0; }
  .verdict-pass { background: #d9f2df !important; color: #1a6b34; font-weight: 600; }
  .verdict-fail { background: #fbdada !important; color: #a12626; font-weight: 600; }
  .verdict-rework { background: #fdf0d0 !important; color: #8a5a00; font-weight: 600; }
  .verdict-partial { background: #fdf6d0 !important; color: #7a6600; }
  .verdict-na { background: #eaeaea !important; color: #666; }
  ul { margin: 0.4em 0; }
</style>
"""


def prefix_pattern(project_map):
    return "|".join(sorted(project_map.keys(), key=len, reverse=True))


def expand_shorthand_id_lists(line, project_map):
    pat = prefix_pattern(project_map)
    if not pat:
        return line
    regex = re.compile(r"\b(%s)-(\d+)((?:\s*,\s*\d+)+)\b" % pat)

    def repl(m):
        prefix, first, rest = m.group(1), m.group(2), m.group(3)
        expanded = re.sub(r"(\d+)", lambda mm: f"{prefix}-{mm.group(1)}", rest)
        return f"{prefix}-{first}{expanded}"

    return regex.sub(repl, line)


def convert_inline(line, project_map):
    line = expand_shorthand_id_lists(line, project_map)
    links = []

    def preserve_link(match):
        label = htmllib.escape(match.group(1), quote=False)
        url = htmllib.escape(match.group(2), quote=True)
        links.append(f'<a href="{url}" target="_blank" rel="noopener">{label}</a>')
        return f"__MARKDOWN_LINK_{len(links) - 1}__"

    line = re.sub(r"\[([^\]]+)\]\((https?://[^)\s]+)\)", preserve_link, line)
    line = htmllib.escape(line, quote=False)
    line = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", line)
    line = re.sub(r"`([^`]+?)`", r"<code>\1</code>", line)
    pat = prefix_pattern(project_map)
    if pat:
        def link(m):
            prefix, num = m.group(1), m.group(2)
            wid = f"{prefix}-{num}"
            url = f"{BASE_URL}/{project_map[prefix]}/workitem?id={wid}"
            return f'<a href="{url}" target="_blank" rel="noopener">{wid}</a>'

        line = re.sub(r"\b(%s)-(\d+)\b" % pat, link, line)
    for index, anchor in enumerate(links):
        line = line.replace(f"__MARKDOWN_LINK_{index}__", anchor)
    return line


def verdict_class(cell):
    if "Fail" in cell:
        return "verdict-fail"
    if "Needs Rework" in cell:
        return "verdict-rework"
    if "Partial" in cell:
        return "verdict-partial"
    if re.search(r"\bPass\b", cell):
        return "verdict-pass"
    if "N/A" in cell:
        return "verdict-na"
    return ""


def convert(md_text, project_map):
    lines = md_text.splitlines()
    out = []
    out.append("<!DOCTYPE html>")
    out.append('<html lang="en"><head><meta charset="utf-8">')
    out.append("<title>ASPICE Check Report</title>")
    out.append(STYLE)
    out.append("</head><body>")

    i = 0
    in_list = False
    n = len(lines)
    while i < n:
        line = lines[i]
        stripped = line.strip()

        if stripped == "":
            if in_list:
                out.append("</ul>")
                in_list = False
            i += 1
            continue

        if stripped == "---":
            if in_list:
                out.append("</ul>")
                in_list = False
            out.append("<hr>")
            i += 1
            continue

        m = re.match(r"^(#{1,4})\s+(.*)$", line)
        if m:
            if in_list:
                out.append("</ul>")
                in_list = False
            level = len(m.group(1))
            out.append(f"<h{level}>{convert_inline(m.group(2), project_map)}</h{level}>")
            i += 1
            continue

        if re.match(r"^\|.*\|\s*$", line) and i + 1 < n and re.match(r"^\|[\s:\-|]+\|\s*$", lines[i + 1]):
            if in_list:
                out.append("</ul>")
                in_list = False
            header_cells = [c.strip() for c in line.strip().strip("|").split("|")]
            out.append("<table><thead><tr>")
            for hc in header_cells:
                out.append(f"<th>{convert_inline(hc, project_map)}</th>")
            out.append("</tr></thead><tbody>")
            i += 2
            while i < n and re.match(r"^\|.*\|\s*$", lines[i]):
                row_cells = [c.strip() for c in lines[i].strip().strip("|").split("|")]
                out.append("<tr>")
                for rc in row_cells:
                    cell_html = convert_inline(rc, project_map)
                    cls = verdict_class(rc)
                    out.append(f'<td class="{cls}">{cell_html}</td>' if cls else f"<td>{cell_html}</td>")
                out.append("</tr>")
                i += 1
            out.append("</tbody></table>")
            continue

        m = re.match(r"^\s*-\s+(.*)$", line)
        if m:
            if not in_list:
                out.append("<ul>")
                in_list = True
            out.append(f"<li>{convert_inline(m.group(1), project_map)}</li>")
            i += 1
            continue

        m = re.match(r"^\s*(\d+)\.\s+(.*)$", line)
        if m:
            if in_list:
                out.append("</ul>")
                in_list = False
            out.append(f"<p><strong>{m.group(1)}.</strong> {convert_inline(m.group(2), project_map)}</p>")
            i += 1
            continue

        if in_list:
            out.append("</ul>")
            in_list = False
        out.append(f"<p>{convert_inline(line, project_map)}</p>")
        i += 1

    if in_list:
        out.append("</ul>")
    out.append("</body></html>")
    return "\n".join(out) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", "-i", required=True)
    ap.add_argument("--output", "-o")
    ap.add_argument("--project-map", help="Extra prefix=project pairs, comma-separated", default="")
    args = ap.parse_args()

    project_map = dict(DEFAULT_PROJECT_MAP)
    if args.project_map:
        for pair in args.project_map.split(","):
            k, _, v = pair.partition("=")
            if k and v:
                project_map[k.strip()] = v.strip()

    output = args.output or os.path.splitext(args.input)[0] + ".html"
    with open(args.input, encoding="utf-8") as f:
        md = f.read()
    with open(output, "w", encoding="utf-8") as f:
        f.write(convert(md, project_map))
    print(f"Written: {output}")


if __name__ == "__main__":
    main()
