#!/usr/bin/env python3
"""
Render Windows Time inventory JSON to standalone SVG and relationship CSV.
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
    "TimeEdgeId",
    "SourceServer",
    "Relationship",
    "Target",
    "TargetType",
    "ActiveSource",
    "SourceType",
    "IsTimeServer",
    "NtpServerEnabled",
    "NtpClientEnabled",
    "Udp123Listening",
    "W32TimeType",
    "ServiceStatus",
    "Stratum",
    "LastSuccessfulSyncTime",
    "Offset",
    "Status",
    "CollectionServer",
    "Notes",
]

COLORS = {
    "background": "#f8fafc",
    "text": "#111827",
    "muted": "#64748b",
    "panel_fill": "#ffffff",
    "panel_stroke": "#cbd5e1",
    "server_fill": "#ecfdf5",
    "server_stroke": "#047857",
    "client_fill": "#eff6ff",
    "client_stroke": "#2563eb",
    "unknown_fill": "#f1f5f9",
    "unknown_stroke": "#64748b",
    "target_fill": "#fff7ed",
    "target_stroke": "#ea580c",
    "row_alt": "#f1f5f9",
    "label_fill": "#ffffff",
    "SyncsFrom": "#2563eb",
    "ConfiguredPeer": "#7c3aed",
    "UsesLocalClock": "#dc2626",
    "UsesHypervisor": "#0891b2",
    "UnknownSource": "#64748b",
    "default_edge": "#475569",
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


def edge_id(row, index):
    existing = clean(row.get("TimeEdgeId"))
    return existing or f"T{index + 1:02d}"


def normalized_edges(inventory):
    rows = []
    for index, edge in enumerate(as_list(inventory.get("TimeEdges"))):
        row = {field: clean(edge.get(field, "")) for field in FIELDS}
        row["TimeEdgeId"] = edge_id(row, index)
        rows.append(row)
    return rows


def normalized_servers(inventory, edges):
    servers = {}
    for server in as_list(inventory.get("Servers")):
        name = clean(server.get("ServerName") or server.get("ComputerName") or server.get("QueriedServer"))
        if not name:
            continue
        servers[name.lower()] = {
            "ServerName": name,
            "Fqdn": clean(server.get("Fqdn")),
            "IsTimeServer": clean(server.get("IsTimeServer")),
            "Source": clean(server.get("Source")),
            "SourceType": clean(server.get("SourceType")),
            "W32TimeType": clean(server.get("W32TimeType")),
            "ServiceStatus": clean(server.get("ServiceStatus")),
            "Stratum": clean(server.get("Stratum")),
            "CollectionStatus": clean(server.get("CollectionStatus") or server.get("Status")),
            "Evidence": clean(server.get("Evidence")),
        }

    for edge in edges:
        name = clean(edge.get("SourceServer"))
        if not name:
            continue
        servers.setdefault(
            name.lower(),
            {
                "ServerName": name,
                "Fqdn": "",
                "IsTimeServer": clean(edge.get("IsTimeServer")),
                "Source": clean(edge.get("ActiveSource")),
                "SourceType": clean(edge.get("SourceType")),
                "W32TimeType": clean(edge.get("W32TimeType")),
                "ServiceStatus": clean(edge.get("ServiceStatus")),
                "Stratum": clean(edge.get("Stratum")),
                "CollectionStatus": clean(edge.get("Status")),
                "Evidence": clean(edge.get("Notes")),
            },
        )
    return servers


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


def card_style(server):
    value = clean(server.get("IsTimeServer")).lower()
    if value == "true":
        return COLORS["server_fill"], COLORS["server_stroke"], "Time server"
    if value == "false":
        return COLORS["client_fill"], COLORS["client_stroke"], "Time client"
    return COLORS["unknown_fill"], COLORS["unknown_stroke"], "Unknown role"


def edge_color(edge):
    return COLORS.get(clean(edge.get("Relationship")), COLORS["default_edge"])


def marker_defs():
    rels = ["SyncsFrom", "ConfiguredPeer", "UsesLocalClock", "UsesHypervisor", "UnknownSource"]
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


def relationship_marker(edge):
    rel = clean(edge.get("Relationship"))
    if rel in {"SyncsFrom", "ConfiguredPeer", "UsesLocalClock", "UsesHypervisor", "UnknownSource"}:
        return f"arrow-{rel}"
    return "arrow-default"


def draw_card(x, y, w, h, title, subtitle=None, fill=None, stroke=None, title_size=14):
    fill = fill or COLORS["panel_fill"]
    stroke = stroke or COLORS["panel_stroke"]
    out = [
        f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="8" fill="{fill}" stroke="{stroke}" stroke-width="1.5"/>',
        svg_text(x + 14, y + 26, split_label(title, 31, 2), size=title_size, weight="700"),
    ]
    if subtitle:
        out.append(svg_text(x + 14, y + h - 18, split_label(subtitle, 45, 2), size=11, fill=COLORS["muted"]))
    return "\n".join(out)


def draw_legend(x, y):
    items = [
        ("Active source", "SyncsFrom"),
        ("Configured peer", "ConfiguredPeer"),
        ("Local clock", "UsesLocalClock"),
        ("Hypervisor", "UsesHypervisor"),
        ("Unknown", "UnknownSource"),
    ]
    out = [svg_text(x, y, ["Relationship Legend"], size=14, weight="700")]
    cursor_y = y + 22
    for label, rel in items:
        color = COLORS[rel]
        out.append(f'<line x1="{x}" y1="{cursor_y}" x2="{x + 34}" y2="{cursor_y}" stroke="{color}" stroke-width="3"/>')
        out.append(svg_text(x + 44, cursor_y + 4, [label], size=12, fill=COLORS["muted"]))
        cursor_y += 22
    return "\n".join(out)


def server_group(server):
    role = clean(server.get("IsTimeServer")).lower()
    if role == "true":
        return "Servers serving time"
    if role == "false":
        return "Servers consuming time"
    return "Unknown time-server status"


def draw_combined_svg(inventory):
    edges = normalized_edges(inventory)
    servers = normalized_servers(inventory, edges)

    server_groups = defaultdict(list)
    for server in servers.values():
        server_groups[server_group(server)].append(server)
    for group in server_groups:
        server_groups[group].sort(key=lambda item: item["ServerName"].lower())

    target_items = {}
    for edge in edges:
        target = clean(edge.get("Target")) or "Unknown"
        target_type = clean(edge.get("TargetType")) or "Unknown"
        key = f"{target_type}|{target}".lower()
        target_items.setdefault(
            key,
            {
                "Target": target,
                "TargetType": target_type,
                "Relationship": clean(edge.get("Relationship")),
                "SourceType": clean(edge.get("SourceType")),
            },
        )

    targets_by_type = defaultdict(list)
    for target in target_items.values():
        targets_by_type[target["TargetType"]].append(target)
    for target_type in targets_by_type:
        targets_by_type[target_type].sort(key=lambda item: item["Target"].lower())

    width = 1800
    margin = 56
    title_h = 120
    server_x = 76
    server_w = 430
    target_x = 1180
    target_w = 500
    card_h = 78
    card_gap = 18
    group_gap = 34
    server_positions = {}
    target_positions = {}

    y = title_h
    group_order = ["Servers serving time", "Servers consuming time", "Unknown time-server status"]
    server_blocks = []
    for group in group_order:
        items = server_groups.get(group, [])
        if not items:
            continue
        group_h = 50 + len(items) * card_h + max(0, len(items) - 1) * card_gap + 24
        server_blocks.append((group, y, group_h, items))
        cursor = y + 52
        for server in items:
            server_positions[server["ServerName"].lower()] = {
                "x": server_x,
                "y": cursor,
                "w": server_w,
                "h": card_h,
            }
            cursor += card_h + card_gap
        y += group_h + group_gap
    left_height = y

    y = title_h
    target_blocks = []
    for target_type in sorted(targets_by_type.keys()):
        targets = targets_by_type[target_type]
        group_h = 50 + len(targets) * card_h + max(0, len(targets) - 1) * card_gap + 24
        target_blocks.append((target_type, y, group_h, targets))
        cursor = y + 52
        for target in targets:
            target_positions[f'{target["TargetType"]}|{target["Target"]}'.lower()] = {
                "x": target_x,
                "y": cursor,
                "w": target_w,
                "h": card_h,
            }
            cursor += card_h + card_gap
        y += group_h + group_gap
    right_height = y

    height = max(left_height, right_height, 720) + 80
    out = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
        marker_defs(),
        f'<rect x="0" y="0" width="{width}" height="{height}" fill="{COLORS["background"]}"/>',
        svg_text(margin, 50, ["Time Source Map - Combined View"], size=30, weight="800"),
        svg_text(margin, 78, ["Windows Time source relationships. Edge IDs map to time-relationship-details.csv."], size=14, fill=COLORS["muted"]),
        draw_legend(1320, 38),
    ]

    for group, block_y, block_h, items in server_blocks:
        out.append(
            f'<rect x="{server_x - 20}" y="{block_y}" width="{server_w + 40}" height="{block_h}" rx="10" '
            f'fill="{COLORS["panel_fill"]}" stroke="{COLORS["panel_stroke"]}" stroke-width="1.5"/>'
        )
        out.append(svg_text(server_x, block_y + 30, [group], size=16, weight="700"))
        for server in items:
            pos = server_positions[server["ServerName"].lower()]
            fill, stroke, role_label = card_style(server)
            details = f'{role_label} | {server.get("SourceType") or "Unknown source"}'
            if server.get("Stratum"):
                details += f' | Stratum {server["Stratum"]}'
            out.append(draw_card(pos["x"], pos["y"], pos["w"], pos["h"], server["ServerName"], details, fill, stroke))

    for target_type, block_y, block_h, targets in target_blocks:
        out.append(
            f'<rect x="{target_x - 20}" y="{block_y}" width="{target_w + 40}" height="{block_h}" rx="10" '
            f'fill="{COLORS["panel_fill"]}" stroke="{COLORS["panel_stroke"]}" stroke-width="1.5"/>'
        )
        out.append(svg_text(target_x, block_y + 30, [target_type], size=16, weight="700"))
        for target in targets:
            pos = target_positions[f'{target["TargetType"]}|{target["Target"]}'.lower()]
            subtitle = f'{target.get("Relationship") or "Relationship"} | {target.get("SourceType") or "Unknown"}'
            out.append(draw_card(pos["x"], pos["y"], pos["w"], pos["h"], target["Target"], subtitle, COLORS["target_fill"], COLORS["target_stroke"]))

    label_offsets = defaultdict(int)
    for index, edge in enumerate(edges):
        source = clean(edge.get("SourceServer")).lower()
        target = clean(edge.get("Target")) or "Unknown"
        target_type = clean(edge.get("TargetType")) or "Unknown"
        source_pos = server_positions.get(source)
        target_pos = target_positions.get(f"{target_type}|{target}".lower())
        if not source_pos or not target_pos:
            continue

        sx = source_pos["x"] + source_pos["w"]
        sy = source_pos["y"] + source_pos["h"] / 2
        tx = target_pos["x"]
        ty = target_pos["y"] + target_pos["h"] / 2
        color = edge_color(edge)
        marker = relationship_marker(edge)
        offset_key = f"{source}|{target_type}|{target}".lower()
        label_offsets[offset_key] += 1
        offset = (label_offsets[offset_key] - 1) * 12
        mid_x = (sx + tx) / 2
        mid_y = (sy + ty) / 2 + offset
        control = max(120, (tx - sx) * 0.33)
        out.append(
            f'<path d="M {sx} {sy} C {sx + control} {sy}, {tx - control} {ty}, {tx} {ty}" '
            f'fill="none" stroke="{color}" stroke-width="2.2" stroke-opacity="0.80" marker-end="url(#{marker})"/>'
        )
        label = edge_id(edge, index)
        out.append(
            f'<rect x="{mid_x - 22}" y="{mid_y - 13}" width="44" height="22" rx="5" '
            f'fill="{COLORS["label_fill"]}" stroke="{color}" stroke-width="1"/>'
        )
        out.append(svg_text(mid_x, mid_y + 4, [label], size=11, weight="700", fill=color, anchor="middle"))

    out.append(svg_text(margin, height - 28, [f"{len(edges)} time-source relationships rendered."], size=12, fill=COLORS["muted"]))
    out.append("</svg>")
    return "\n".join(out)


def draw_source_svg(inventory):
    edges = normalized_edges(inventory)
    servers = normalized_servers(inventory, edges)
    edges_by_server = defaultdict(list)
    for edge in edges:
        edges_by_server[clean(edge.get("SourceServer")).lower()].append(edge)

    ordered_servers = sorted(servers.values(), key=lambda item: (server_group(item), item["ServerName"].lower()))
    width = 1800
    margin = 56
    lane_x = 64
    lane_w = width - 128
    top = 116
    lane_gap = 28
    row_h = 34
    lane_min_h = 178
    y = top
    lanes = []
    for server in ordered_servers:
        server_edges = edges_by_server.get(server["ServerName"].lower(), [])
        lane_h = max(lane_min_h, 116 + max(1, len(server_edges)) * row_h)
        lanes.append((server, server_edges, y, lane_h))
        y += lane_h + lane_gap
    height = max(y + 44, 640)

    out = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
        marker_defs(),
        f'<rect x="0" y="0" width="{width}" height="{height}" fill="{COLORS["background"]}"/>',
        svg_text(margin, 50, ["Time Source Map - Source View"], size=30, weight="800"),
        svg_text(margin, 78, ["One lane per server with active source, configured peers, and time-server evidence."], size=14, fill=COLORS["muted"]),
    ]

    columns = [
        ("ID", 70),
        ("Relationship", 160),
        ("Target", 300),
        ("Type", 170),
        ("W32Type", 100),
        ("Stratum", 86),
        ("Status", 110),
        ("Notes", lane_w - 40 - 70 - 160 - 300 - 170 - 100 - 86 - 110),
    ]

    for server, server_edges, lane_y, lane_h in lanes:
        out.append(
            f'<rect x="{lane_x}" y="{lane_y}" width="{lane_w}" height="{lane_h}" rx="10" '
            f'fill="{COLORS["panel_fill"]}" stroke="{COLORS["panel_stroke"]}" stroke-width="1.5"/>'
        )
        fill, stroke, role_label = card_style(server)
        subtitle = f'{role_label} | {server.get("SourceType") or "Unknown source"} | Service: {server.get("ServiceStatus") or "Unknown"}'
        out.append(draw_card(lane_x + 20, lane_y + 22, 440, 76, server["ServerName"], subtitle, fill, stroke))
        evidence = server.get("Evidence") or "No evidence summary"
        out.append(draw_card(lane_x + 480, lane_y + 22, lane_w - 520, 76, "Evidence", evidence, COLORS["panel_fill"], COLORS["panel_stroke"], title_size=13))

        header_y = lane_y + 122
        cursor_x = lane_x + 20
        out.append(f'<rect x="{cursor_x}" y="{header_y - 22}" width="{lane_w - 40}" height="30" fill="{COLORS["row_alt"]}" stroke="{COLORS["panel_stroke"]}"/>')
        for title, col_w in columns:
            out.append(svg_text(cursor_x + 8, header_y - 2, [title], size=11, weight="700", fill=COLORS["muted"]))
            cursor_x += col_w

        row_y = header_y + 12
        if not server_edges:
            out.append(svg_text(lane_x + 28, row_y + 18, ["No time-source relationships were found for this server."], size=12, fill=COLORS["muted"]))
            continue

        for row_index, edge in enumerate(sorted(server_edges, key=lambda item: (clean(item.get("Relationship")), clean(item.get("Target"))))):
            fill_row = COLORS["panel_fill"] if row_index % 2 == 0 else COLORS["row_alt"]
            out.append(f'<rect x="{lane_x + 20}" y="{row_y}" width="{lane_w - 40}" height="{row_h}" fill="{fill_row}" stroke="{COLORS["panel_stroke"]}" stroke-width="0.6"/>')
            values = [
                edge_id(edge, row_index),
                clean(edge.get("Relationship")),
                clean(edge.get("Target")),
                clean(edge.get("TargetType")),
                clean(edge.get("W32TimeType")),
                clean(edge.get("Stratum")),
                clean(edge.get("Status")),
                clean(edge.get("Notes")),
            ]
            cursor_x = lane_x + 20
            for value, (_, col_w) in zip(values, columns):
                out.append(svg_text(cursor_x + 8, row_y + 22, split_label(value, 34, 1), size=11, fill=COLORS["text"]))
                cursor_x += col_w
            row_y += row_h

    out.append("</svg>")
    return "\n".join(out)


def main():
    parser = argparse.ArgumentParser(description="Render Windows Time inventory to SVG.")
    parser.add_argument("--inventory", required=True, help="Path to inventory.json")
    parser.add_argument("--output", required=True, help="Path to output SVG")
    parser.add_argument("--view", choices=["combined", "source"], default="combined")
    parser.add_argument("--details-csv", help="Optional path to write time-relationship-details.csv")
    args = parser.parse_args()

    inventory = read_inventory(args.inventory)
    rows = normalized_edges(inventory)
    if args.details_csv:
        write_csv(args.details_csv, rows)

    if args.view == "combined":
        svg = draw_combined_svg(inventory)
    else:
        svg = draw_source_svg(inventory)

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(svg, encoding="utf-8")


if __name__ == "__main__":
    main()
