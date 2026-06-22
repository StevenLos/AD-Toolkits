#!/usr/bin/env python3
"""
Render AD forest configuration inventory JSON or relationship CSV to SVG.

The renderer is dependency-light and intentionally diagram-oriented. It shows
forest configuration relationships with stable edge IDs that map back to
forest-config-relationships.csv.
"""

from __future__ import annotations

import argparse
import csv
import html
import json
from datetime import datetime, timezone
from pathlib import Path
from textwrap import wrap


FIELDS = [
    "ForestConfigEdgeId",
    "Source",
    "SourceType",
    "Relationship",
    "Target",
    "TargetType",
    "PartitionType",
    "NamingContext",
    "DomainName",
    "ReplicaServers",
    "Status",
    "SourceCollection",
    "Notes",
]

COLORS = {
    "background": "#f8fafc",
    "text": "#111827",
    "muted": "#64748b",
    "row_alt": "#eef2f7",
    "panel": "#ffffff",
    "stroke": "#cbd5e1",
    "Forest": ("#eff6ff", "#2563eb"),
    "Domain": ("#ecfdf5", "#059669"),
    "Schema": ("#faf5ff", "#9333ea"),
    "NamingContext": ("#fff7ed", "#ea580c"),
    "ApplicationPartition": ("#fefce8", "#ca8a04"),
    "DnsApplicationPartition": ("#ecfeff", "#0891b2"),
    "DomainController": ("#f1f5f9", "#475569"),
    "GlobalCatalog": ("#f1f5f9", "#475569"),
    "OptionalFeature": ("#fdf2f8", "#db2777"),
    "Suffix": ("#f5f5f4", "#78716c"),
}

EDGE_COLORS = {
    "ContainsDomain": "#059669",
    "HasNamingContext": "#ea580c",
    "HasApplicationPartition": "#ca8a04",
    "HasDnsApplicationPartition": "#0891b2",
    "ReplicatedTo": "#2563eb",
    "SchemaMaster": "#9333ea",
    "DomainNamingMaster": "#4f46e5",
    "EnabledOptionalFeature": "#db2777",
    "ConfiguredSuffix": "#78716c",
}

FONT = "Inter, Segoe UI, Arial, sans-serif"


def clean(value) -> str:
    return str(value or "").strip()


def xml(value) -> str:
    return html.escape(clean(value), quote=True)


def as_list(value):
    if value is None:
        return []
    if isinstance(value, list):
        return value
    if isinstance(value, dict) and not value:
        return []
    return [value]


def read_csv(path: Path):
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        rows = []
        for row in reader:
            rows.append({field: clean(row.get(field, "")) for field in FIELDS})
        return rows


def write_csv(path: Path, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=FIELDS)
        writer.writeheader()
        for row in rows:
            writer.writerow({field: clean(row.get(field, "")) for field in FIELDS})


def csv_to_inventory(path: Path):
    rows = read_csv(path)
    return {
        "Metadata": {
            "Source": "ForestConfigRelationshipCsv",
            "InputFile": str(path),
            "GeneratedAtUtc": datetime.now(timezone.utc).isoformat(),
        },
        "Relationships": rows,
    }


def load_inventory(args):
    if args.inventory:
        with Path(args.inventory).open("r", encoding="utf-8-sig") as handle:
            return json.load(handle)
    if args.csv:
        return csv_to_inventory(Path(args.csv))
    raise SystemExit("Either --inventory or --csv is required.")


def relationship_rows(inventory):
    rows = []
    for index, row in enumerate(as_list(inventory.get("Relationships"))):
        normalized = {field: clean(row.get(field, "")) for field in FIELDS}
        if not normalized["ForestConfigEdgeId"]:
            normalized["ForestConfigEdgeId"] = f"F{index + 1:03d}"
        rows.append(normalized)
    return rows


def filtered_rows(rows, view):
    if view == "combined":
        return rows
    partition_relationships = {
        "HasApplicationPartition",
        "HasDnsApplicationPartition",
        "ReplicatedTo",
    }
    subset = [
        row
        for row in rows
        if row.get("Relationship") in partition_relationships
        or row.get("PartitionType") in ("Application", "DNSApplication")
    ]
    return subset or rows


def split_label(text, width=30, max_lines=3):
    text = clean(text)
    if not text:
        return [""]
    lines = []
    for part in text.splitlines():
        lines.extend(wrap(part, width=width, break_long_words=False) or [part])
    if len(lines) > max_lines:
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


def node_colors(node_type):
    return COLORS.get(clean(node_type), ("#ffffff", "#94a3b8"))


def draw_node(x, y, width, height, title, node_type):
    fill, stroke = node_colors(node_type)
    lines = [
        f'<rect x="{x}" y="{y}" width="{width}" height="{height}" rx="8" fill="{fill}" stroke="{stroke}" stroke-width="1.5"/>',
        svg_text(x + 16, y + 23, split_label(title, width=32, max_lines=2), size=13, weight="700"),
        svg_text(x + 16, y + height - 17, [node_type or "Object"], size=11, fill=COLORS["muted"]),
    ]
    return "\n".join(lines)


def draw_arrow(x1, y1, x2, y2, color):
    return "\n".join(
        [
            f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{color}" stroke-width="2.2" marker-end="url(#arrow)"/>',
        ]
    )


def render_svg(inventory, rows, view):
    rows = filtered_rows(rows, view)
    title = "AD Forest Configuration"
    if view == "partitions":
        title = "AD Forest Partitions and Replicas"

    row_height = 102
    top = 126
    width = 1180
    height = max(340, top + (len(rows) * row_height) + 72)
    source_x = 56
    target_x = 764
    node_w = 330
    node_h = 72
    line_start_x = source_x + node_w
    line_end_x = target_x
    label_x = (line_start_x + line_end_x) / 2

    generated = clean(inventory.get("Metadata", {}).get("GeneratedAtUtc")) or datetime.now(timezone.utc).isoformat()
    source = clean(inventory.get("Metadata", {}).get("Source"))

    out = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
        "<defs>",
        '<marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">',
        '<path d="M 0 0 L 10 5 L 0 10 z" fill="#475569"/>',
        "</marker>",
        "</defs>",
        f'<rect width="{width}" height="{height}" fill="{COLORS["background"]}"/>',
        svg_text(56, 48, [title], size=25, weight="800"),
        svg_text(56, 76, [f"View: {view} | Relationships: {len(rows)} | Source: {source or 'inventory'}"], size=13, fill=COLORS["muted"]),
        svg_text(56, 98, [f"Generated: {generated}"], size=12, fill=COLORS["muted"]),
    ]

    if not rows:
        out.append(svg_text(56, 170, ["No relationships were found in the inventory."], size=16, weight="700"))
        out.append("</svg>")
        return "\n".join(out)

    for index, row in enumerate(rows):
        y = top + index * row_height
        center_y = y + node_h / 2
        if index % 2 == 1:
            out.append(f'<rect x="32" y="{y - 15}" width="{width - 64}" height="{row_height - 12}" rx="8" fill="{COLORS["row_alt"]}" opacity="0.65"/>')

        source_label = row.get("Source") or "Unknown source"
        source_type = row.get("SourceType") or "Object"
        target_label = row.get("Target") or "Unknown target"
        target_type = row.get("TargetType") or "Object"
        relationship = row.get("Relationship") or "Relationship"
        edge_id = row.get("ForestConfigEdgeId") or f"F{index + 1:03d}"
        color = EDGE_COLORS.get(relationship, "#475569")

        out.append(draw_node(source_x, y, node_w, node_h, source_label, source_type))
        out.append(draw_node(target_x, y, node_w, node_h, target_label, target_type))
        out.append(draw_arrow(line_start_x + 12, center_y, line_end_x - 12, center_y, color))

        label_lines = split_label(f"{edge_id} {relationship}", width=28, max_lines=2)
        label_h = 26 + max(0, len(label_lines) - 1) * 14
        out.append(f'<rect x="{label_x - 120}" y="{center_y - label_h / 2}" width="240" height="{label_h}" rx="7" fill="#ffffff" stroke="{color}" stroke-width="1"/>')
        out.append(svg_text(label_x, center_y - 2, label_lines, size=12, weight="700", fill=color, anchor="middle", line_height=14))

        context = []
        if row.get("PartitionType"):
            context.append(f"Partition: {row['PartitionType']}")
        if row.get("DomainName"):
            context.append(f"Domain: {row['DomainName']}")
        if row.get("Status"):
            context.append(f"Status: {row['Status']}")
        if context:
            out.append(svg_text(label_x, center_y + 24, [" | ".join(context)], size=10, fill=COLORS["muted"], anchor="middle"))

    out.append("</svg>")
    return "\n".join(out)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--inventory", help="Path to inventory.json")
    parser.add_argument("--csv", help="Path to forest-config-relationships.csv")
    parser.add_argument("--output", required=True, help="Output SVG path")
    parser.add_argument("--view", choices=["combined", "partitions"], default="combined")
    parser.add_argument("--details-csv", help="Optional relationship CSV output path")
    args = parser.parse_args()

    inventory = load_inventory(args)
    rows = relationship_rows(inventory)
    if args.details_csv:
        write_csv(Path(args.details_csv), rows)

    svg = render_svg(inventory, rows, args.view)
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(svg, encoding="utf-8")


if __name__ == "__main__":
    main()

