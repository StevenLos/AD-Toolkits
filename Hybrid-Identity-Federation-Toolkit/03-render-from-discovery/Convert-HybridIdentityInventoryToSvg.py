#!/usr/bin/env python3
"""
Render hybrid identity and federation inventory JSON to standalone SVG diagrams.
"""

from __future__ import annotations

import argparse
import csv
import html
import json
from collections import defaultdict
from pathlib import Path
from textwrap import wrap


FIELDS = [
    "HybridEdgeId",
    "Source",
    "SourceType",
    "Relationship",
    "Target",
    "TargetType",
    "Label",
    "Status",
    "SourceCollection",
    "Notes",
]

COLORS = {
    "background": "#f8fafc",
    "text": "#111827",
    "muted": "#64748b",
    "panel_fill": "#ffffff",
    "panel_stroke": "#cbd5e1",
    "ad_fill": "#ecfdf5",
    "ad_stroke": "#047857",
    "sync_fill": "#eff6ff",
    "sync_stroke": "#2563eb",
    "cloud_fill": "#f0f9ff",
    "cloud_stroke": "#0284c7",
    "adfs_fill": "#fff7ed",
    "adfs_stroke": "#ea580c",
    "rp_fill": "#f8fafc",
    "rp_stroke": "#64748b",
    "pta_fill": "#fefce8",
    "pta_stroke": "#ca8a04",
    "finding_fill": "#fef2f2",
    "finding_stroke": "#dc2626",
    "row_alt": "#f1f5f9",
    "SyncImport": "#2563eb",
    "SyncExport": "#0284c7",
    "Writeback": "#7c3aed",
    "Federates": "#ea580c",
    "IssuesTokenTo": "#475569",
    "AuthenticatesVia": "#ca8a04",
    "default_edge": "#64748b",
}

FONT = "Inter, Segoe UI, Arial, sans-serif"


def as_list(value):
    if value is None:
        return []
    if isinstance(value, list):
        return value
    if isinstance(value, dict) and not value:
        return []
    return [value]


def clean(value):
    return str(value or "").strip()


def xml(value):
    return html.escape(str(value or ""), quote=True)


def read_inventory(path):
    with Path(path).open("r", encoding="utf-8-sig") as handle:
        return json.load(handle)


def write_csv(path, rows):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=FIELDS)
        writer.writeheader()
        for row in rows:
            writer.writerow({field: clean(row.get(field, "")) for field in FIELDS})


def normalized_edges(inventory):
    rows = []
    for index, edge in enumerate(as_list(inventory.get("TopologyEdges"))):
        row = {field: clean(edge.get(field, "")) for field in FIELDS}
        if not row["HybridEdgeId"]:
            row["HybridEdgeId"] = f"HI{index + 1:02d}"
        rows.append(row)
    return rows


def split_label(text, width=30, max_lines=3):
    text = clean(text)
    if not text:
        return [""]
    lines = []
    for part in text.splitlines():
        lines.extend(wrap(part, width=width, break_long_words=False) or [part])
    if len(lines) > max_lines:
        if max_lines <= 1:
            first = lines[0]
            if len(first) > width:
                first = first[: max(1, width - 3)] + "..."
            return [first]
        return lines[: max_lines - 1] + ["..."]
    return lines


def svg_text(x, y, lines, size=13, weight="400", fill=None, anchor="start", line_height=17):
    fill = fill or COLORS["text"]
    out = [
        f'<text x="{x}" y="{y}" font-family="{FONT}" font-size="{size}" '
        f'font-weight="{weight}" fill="{fill}" text-anchor="{anchor}">'
    ]
    for index, line in enumerate(lines):
        dy = 0 if index == 0 else line_height
        out.append(f'<tspan x="{x}" dy="{dy}">{xml(line)}</tspan>')
    out.append("</text>")
    return "\n".join(out)


def card_style(node_type):
    node_type = clean(node_type)
    if node_type in {"ADForest", "ADDomain", "ADOU"}:
        return COLORS["ad_fill"], COLORS["ad_stroke"]
    if node_type == "EntraConnectServer":
        return COLORS["sync_fill"], COLORS["sync_stroke"]
    if node_type == "CloudIdentity":
        return COLORS["cloud_fill"], COLORS["cloud_stroke"]
    if node_type == "AdfsFarm":
        return COLORS["adfs_fill"], COLORS["adfs_stroke"]
    if node_type == "PtaAgent":
        return COLORS["pta_fill"], COLORS["pta_stroke"]
    if node_type == "RelyingParty":
        return COLORS["rp_fill"], COLORS["rp_stroke"]
    return COLORS["panel_fill"], COLORS["panel_stroke"]


def relationship_color(edge):
    return COLORS.get(clean(edge.get("Relationship")), COLORS["default_edge"])


def marker_defs():
    rels = ["SyncImport", "SyncExport", "Writeback", "Federates", "IssuesTokenTo", "AuthenticatesVia"]
    marker_items = []
    for rel in rels:
        color = COLORS[rel]
        marker_items.append(
            f'<marker id="arrow-{rel}" viewBox="0 0 10 10" refX="9" refY="5" '
            f'markerWidth="8" markerHeight="8" orient="auto-start-reverse">'
            f'<path d="M 0 0 L 10 5 L 0 10 z" fill="{color}"/></marker>'
        )
    marker_items.append(
        f'<marker id="arrow-default" viewBox="0 0 10 10" refX="9" refY="5" '
        f'markerWidth="8" markerHeight="8" orient="auto-start-reverse">'
        f'<path d="M 0 0 L 10 5 L 0 10 z" fill="{COLORS["default_edge"]}"/></marker>'
    )
    return "<defs>\n" + "\n".join(marker_items) + "\n</defs>"


def marker(edge):
    rel = clean(edge.get("Relationship"))
    if rel in {"SyncImport", "SyncExport", "Writeback", "Federates", "IssuesTokenTo", "AuthenticatesVia"}:
        return f"arrow-{rel}"
    return "arrow-default"


def draw_card(x, y, w, h, title, subtitle, node_type):
    fill, stroke = card_style(node_type)
    title_lines = split_label(title, 30, 2)
    subtitle_lines = split_label(subtitle, 38, 2) if subtitle else []
    out = [
        f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="8" fill="{fill}" stroke="{stroke}" stroke-width="1.5"/>',
        svg_text(x + 14, y + 26, title_lines, size=14, weight="700"),
    ]
    if subtitle_lines:
        out.append(svg_text(x + 14, y + h - 20, subtitle_lines, size=11, fill=COLORS["muted"]))
    return "\n".join(out)


def draw_legend(x, y):
    items = [
        ("AD import", "SyncImport"),
        ("Cloud export", "SyncExport"),
        ("Writeback", "Writeback"),
        ("Federation", "Federates"),
        ("Relying party", "IssuesTokenTo"),
        ("PTA", "AuthenticatesVia"),
    ]
    out = [svg_text(x, y, ["Relationship Legend"], size=14, weight="700")]
    cursor_y = y + 22
    for label, rel in items:
        color = COLORS[rel]
        out.append(f'<line x1="{x}" y1="{cursor_y}" x2="{x + 34}" y2="{cursor_y}" stroke="{color}" stroke-width="3"/>')
        out.append(svg_text(x + 44, cursor_y + 4, [label], size=12, fill=COLORS["muted"]))
        cursor_y += 22
    return "\n".join(out)


def inventory_nodes(edges):
    nodes = {}
    for edge in edges:
        source = clean(edge.get("Source"))
        target = clean(edge.get("Target"))
        if source:
            nodes.setdefault(
                f'{clean(edge.get("SourceType"))}|{source}'.lower(),
                {"Name": source, "Type": clean(edge.get("SourceType")) or "Unknown", "Notes": ""},
            )
        if target:
            nodes.setdefault(
                f'{clean(edge.get("TargetType"))}|{target}'.lower(),
                {"Name": target, "Type": clean(edge.get("TargetType")) or "Unknown", "Notes": ""},
            )
    return nodes


def node_column(node_type):
    if node_type in {"ADForest", "ADDomain", "ADOU"}:
        return "onprem"
    if node_type in {"EntraConnectServer", "PtaAgent"}:
        return "sync"
    if node_type == "CloudIdentity":
        return "cloud"
    if node_type == "AdfsFarm":
        return "federation"
    if node_type == "RelyingParty":
        return "apps"
    return "other"


def draw_combined_svg(inventory):
    edges = normalized_edges(inventory)
    nodes = inventory_nodes(edges)

    columns = {
        "onprem": {"title": "On-premises directories", "x": 60, "w": 310},
        "sync": {"title": "Sync and PTA", "x": 430, "w": 310},
        "cloud": {"title": "Microsoft Entra ID", "x": 800, "w": 310},
        "federation": {"title": "AD FS and WAP", "x": 1170, "w": 310},
        "apps": {"title": "Relying parties", "x": 1540, "w": 310},
    }
    grouped = defaultdict(list)
    for node in nodes.values():
        grouped[node_column(node["Type"])].append(node)
    for items in grouped.values():
        items.sort(key=lambda item: (item["Type"], item["Name"].lower()))

    width = 1910
    margin_top = 126
    card_h = 78
    gap = 18
    positions = {}
    content_height = margin_top
    column_blocks = []
    for key, col in columns.items():
        items = grouped.get(key, [])
        height = 48 + max(1, len(items)) * card_h + max(0, len(items) - 1) * gap + 28
        content_height = max(content_height, margin_top + height)
        column_blocks.append((key, col, items, height))

    height = max(720, content_height + 170)
    out = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
        f'<rect width="{width}" height="{height}" fill="{COLORS["background"]}"/>',
        marker_defs(),
        svg_text(60, 52, ["Hybrid Identity and Federation Topology"], size=26, weight="800"),
        svg_text(60, 82, ["Current-state relationships from normalized inventory. Edge labels map to topology-relationships.csv."], size=13, fill=COLORS["muted"]),
    ]

    for key, col, items, block_h in column_blocks:
        x = col["x"]
        w = col["w"]
        out.append(f'<rect x="{x}" y="{margin_top}" width="{w}" height="{block_h}" rx="10" fill="{COLORS["panel_fill"]}" stroke="{COLORS["panel_stroke"]}"/>')
        out.append(svg_text(x + 16, margin_top + 30, [col["title"]], size=14, weight="700"))
        cursor_y = margin_top + 52
        if not items:
            out.append(draw_card(x + 14, cursor_y, w - 28, card_h, "No discovered objects", "", "Unknown"))
        for node in items:
            positions[f'{node["Type"]}|{node["Name"]}'.lower()] = {"x": x + 14, "y": cursor_y, "w": w - 28, "h": card_h}
            out.append(draw_card(x + 14, cursor_y, w - 28, card_h, node["Name"], node["Type"], node["Type"]))
            cursor_y += card_h + gap

    for edge in edges:
        source_key = f'{clean(edge.get("SourceType"))}|{clean(edge.get("Source"))}'.lower()
        target_key = f'{clean(edge.get("TargetType"))}|{clean(edge.get("Target"))}'.lower()
        if source_key not in positions or target_key not in positions:
            continue
        source = positions[source_key]
        target = positions[target_key]
        sx = source["x"] + source["w"]
        sy = source["y"] + source["h"] / 2
        tx = target["x"]
        ty = target["y"] + target["h"] / 2
        if target["x"] < source["x"]:
            sx = source["x"]
            tx = target["x"] + target["w"]
        mid = (sx + tx) / 2
        color = relationship_color(edge)
        out.append(
            f'<path d="M {sx:.1f} {sy:.1f} C {mid:.1f} {sy:.1f}, {mid:.1f} {ty:.1f}, {tx:.1f} {ty:.1f}" '
            f'fill="none" stroke="{color}" stroke-width="2.3" marker-end="url(#{marker(edge)})"/>'
        )
        label = clean(edge.get("HybridEdgeId"))
        out.append(
            f'<rect x="{mid - 22:.1f}" y="{(sy + ty) / 2 - 13:.1f}" width="44" height="21" rx="6" '
            f'fill="#ffffff" stroke="{color}" stroke-width="1"/>'
        )
        out.append(svg_text(mid, (sy + ty) / 2 + 4, [label], size=11, weight="700", fill=color, anchor="middle"))

    out.append(draw_legend(60, height - 128))
    out.append(svg_text(width - 60, height - 32, ["Generated by Hybrid Identity Federation Toolkit"], size=11, fill=COLORS["muted"], anchor="end"))
    out.append("</svg>")
    return "\n".join(out)


def draw_federation_svg(inventory):
    all_edges = normalized_edges(inventory)
    edges = [
        edge
        for edge in all_edges
        if clean(edge.get("Relationship")) in {"Federates", "IssuesTokenTo", "AuthenticatesVia"}
        or clean(edge.get("SourceType")) in {"AdfsFarm", "PtaAgent"}
        or clean(edge.get("TargetType")) in {"RelyingParty", "CloudIdentity"}
    ]
    if not edges:
        edges = all_edges
    nodes = inventory_nodes(edges)

    farms = [n for n in nodes.values() if n["Type"] == "AdfsFarm"]
    cloud = [n for n in nodes.values() if n["Type"] == "CloudIdentity"]
    pta = [n for n in nodes.values() if n["Type"] == "PtaAgent"]
    rps = [n for n in nodes.values() if n["Type"] == "RelyingParty"]
    other = [n for n in nodes.values() if n not in farms + cloud + pta + rps]
    for group in (farms, cloud, pta, rps, other):
        group.sort(key=lambda item: item["Name"].lower())

    width = 1560
    height = max(720, 180 + max(len(farms) + len(pta), len(cloud), len(rps), len(other), 1) * 92)
    positions = {}
    columns = [
        ("Federation and PTA", 70, farms + pta),
        ("Microsoft Entra ID", 590, cloud),
        ("Relying parties", 1110, rps + other),
    ]
    card_w = 360
    card_h = 74
    gap = 20

    out = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
        f'<rect width="{width}" height="{height}" fill="{COLORS["background"]}"/>',
        marker_defs(),
        svg_text(60, 52, ["Federation and Authentication Topology"], size=26, weight="800"),
        svg_text(60, 82, ["AD FS, PTA, Microsoft Entra ID, and relying-party relationships from inventory."], size=13, fill=COLORS["muted"]),
    ]

    for title, x, items in columns:
        out.append(svg_text(x, 128, [title], size=15, weight="700"))
        cursor_y = 152
        if not items:
            out.append(draw_card(x, cursor_y, card_w, card_h, "No discovered objects", "", "Unknown"))
        for node in items:
            positions[f'{node["Type"]}|{node["Name"]}'.lower()] = {"x": x, "y": cursor_y, "w": card_w, "h": card_h}
            out.append(draw_card(x, cursor_y, card_w, card_h, node["Name"], node["Type"], node["Type"]))
            cursor_y += card_h + gap

    for edge in edges:
        source_key = f'{clean(edge.get("SourceType"))}|{clean(edge.get("Source"))}'.lower()
        target_key = f'{clean(edge.get("TargetType"))}|{clean(edge.get("Target"))}'.lower()
        if source_key not in positions or target_key not in positions:
            continue
        source = positions[source_key]
        target = positions[target_key]
        sx = source["x"] + source["w"]
        sy = source["y"] + source["h"] / 2
        tx = target["x"]
        ty = target["y"] + target["h"] / 2
        if target["x"] < source["x"]:
            sx = source["x"]
            tx = target["x"] + target["w"]
        mid = (sx + tx) / 2
        color = relationship_color(edge)
        out.append(
            f'<path d="M {sx:.1f} {sy:.1f} C {mid:.1f} {sy:.1f}, {mid:.1f} {ty:.1f}, {tx:.1f} {ty:.1f}" '
            f'fill="none" stroke="{color}" stroke-width="2.3" marker-end="url(#{marker(edge)})"/>'
        )
        out.append(svg_text(mid, (sy + ty) / 2 - 8, [clean(edge.get("HybridEdgeId"))], size=11, weight="700", fill=color, anchor="middle"))

    out.append(draw_legend(60, height - 128))
    out.append(svg_text(width - 60, height - 32, ["Generated by Hybrid Identity Federation Toolkit"], size=11, fill=COLORS["muted"], anchor="end"))
    out.append("</svg>")
    return "\n".join(out)


def main():
    parser = argparse.ArgumentParser(description="Render hybrid identity inventory to SVG.")
    parser.add_argument("--inventory", required=True, help="Path to inventory.json")
    parser.add_argument("--output", required=True, help="Output SVG path")
    parser.add_argument("--view", choices=["combined", "federation"], default="combined")
    parser.add_argument("--details-csv", help="Optional topology relationship CSV output")
    args = parser.parse_args()

    inventory = read_inventory(args.inventory)
    edges = normalized_edges(inventory)
    if args.details_csv:
        write_csv(args.details_csv, edges)

    if args.view == "federation":
        svg = draw_federation_svg(inventory)
    else:
        svg = draw_combined_svg(inventory)

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(svg, encoding="utf-8")


if __name__ == "__main__":
    main()
