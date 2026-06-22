#!/usr/bin/env python3
"""
Render AD domain controller health inventory JSON or relationship CSV to SVG.

The renderer is dependency-light and supports both workflows:
- inventory.json -> combined/source SVG and relationship CSV
- dc-health-relationship-details.csv -> combined/source SVG and minimal inventory
"""

from __future__ import annotations

import argparse
import csv
import html
import json
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from textwrap import wrap


FIELDS = [
    "DcHealthEdgeId",
    "Source",
    "SourceType",
    "Relationship",
    "Target",
    "TargetType",
    "DomainName",
    "SiteName",
    "RoleName",
    "Severity",
    "Status",
    "Notes",
]

COLORS = {
    "background": "#f8fafc",
    "text": "#111827",
    "muted": "#64748b",
    "panel_fill": "#ffffff",
    "panel_stroke": "#cbd5e1",
    "row_alt": "#f1f5f9",
    "label_fill": "#ffffff",
    "ok_fill": "#ecfdf5",
    "ok_stroke": "#059669",
    "warning_fill": "#fffbeb",
    "warning_stroke": "#d97706",
    "critical_fill": "#fef2f2",
    "critical_stroke": "#dc2626",
    "unknown_fill": "#f1f5f9",
    "unknown_stroke": "#64748b",
    "target_fill": "#eff6ff",
    "target_stroke": "#2563eb",
    "ServesDomain": "#2563eb",
    "LocatedInSite": "#0891b2",
    "HoldsFsmo": "#7c3aed",
    "UsesTimeSource": "#059669",
    "HasFinding": "#dc2626",
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


def severity_rank(value):
    value = clean(value).lower()
    if value == "critical":
        return 3
    if value == "warning":
        return 2
    if value == "info":
        return 1
    return 0


def highest_severity(items):
    highest = "Info"
    for item in items:
        severity = clean(item.get("Severity") or item.get("HighestSeverity"))
        if severity_rank(severity) > severity_rank(highest):
            highest = severity
    return highest


def read_inventory(path):
    with Path(path).open("r", encoding="utf-8-sig") as handle:
        return json.load(handle)


def read_csv(path):
    with Path(path).open("r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        return [{field: clean(row.get(field, "")) for field in FIELDS} for row in reader]


def write_csv(path, rows):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=FIELDS)
        writer.writeheader()
        for row in rows:
            writer.writerow({field: clean(row.get(field, "")) for field in FIELDS})


def write_inventory(path, inventory):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(inventory, indent=2), encoding="utf-8")


def edge_id(row, index):
    return clean(row.get("DcHealthEdgeId")) or f"DCH{index + 1:03d}"


def normalized_edges(inventory):
    rows = []
    for index, edge in enumerate(as_list(inventory.get("DiagramEdges"))):
        row = {field: clean(edge.get(field, "")) for field in FIELDS}
        row["DcHealthEdgeId"] = edge_id(row, index)
        if not row["Severity"]:
            row["Severity"] = "Info"
        if not row["Status"]:
            row["Status"] = "OK"
        rows.append(row)
    return rows


def csv_to_inventory(path):
    rows = read_csv(path)
    by_source = defaultdict(list)
    for row in rows:
        if clean(row.get("SourceType")) == "DomainController":
            by_source[clean(row.get("Source"))].append(row)

    dcs = []
    for index, (source, edges) in enumerate(sorted(by_source.items(), key=lambda item: item[0].lower())):
        first = edges[0] if edges else {}
        severity = highest_severity(edges)
        dcs.append(
            {
                "DomainControllerId": f"CSV{index + 1:03d}",
                "HostName": source,
                "DomainName": clean(first.get("DomainName")),
                "SiteName": clean(first.get("SiteName")),
                "HighestSeverity": severity,
                "Status": "Blocked" if severity == "Critical" else "Review" if severity == "Warning" else "OK",
                "Notes": "Derived from relationship CSV.",
            }
        )

    return {
        "Metadata": {
            "Source": "DcHealthRelationshipCsv",
            "GeneratedAtUtc": datetime.now(timezone.utc).isoformat(),
        },
        "DomainControllers": dcs,
        "DiagramEdges": rows,
    }


def normalized_dcs(inventory, edges):
    dcs = {}
    for dc in as_list(inventory.get("DomainControllers")):
        host = clean(dc.get("HostName") or dc.get("Name"))
        if not host:
            continue
        dcs[host.lower()] = {
            "DomainControllerId": clean(dc.get("DomainControllerId")),
            "HostName": host,
            "DomainName": clean(dc.get("DomainName")),
            "SiteName": clean(dc.get("SiteName")) or "Unknown Site",
            "IsGlobalCatalog": clean(dc.get("IsGlobalCatalog")),
            "IsReadOnly": clean(dc.get("IsReadOnly")),
            "Enabled": clean(dc.get("Enabled")),
            "OperatingSystem": clean(dc.get("OperatingSystem")),
            "LdapReachable": clean(dc.get("LdapReachable")),
            "CoreServicesStatus": clean(dc.get("CoreServicesStatus")),
            "TimeSource": clean(dc.get("TimeSource")),
            "FsmoRoles": clean(dc.get("FsmoRoles")),
            "FindingCount": clean(dc.get("FindingCount")),
            "HighestSeverity": clean(dc.get("HighestSeverity")) or "Info",
            "Status": clean(dc.get("Status")) or "OK",
            "Notes": clean(dc.get("Notes")),
        }

    for edge in edges:
        if clean(edge.get("SourceType")) != "DomainController":
            continue
        host = clean(edge.get("Source"))
        if not host:
            continue
        dcs.setdefault(
            host.lower(),
            {
                "DomainControllerId": "",
                "HostName": host,
                "DomainName": clean(edge.get("DomainName")),
                "SiteName": clean(edge.get("SiteName")) or "Unknown Site",
                "IsGlobalCatalog": "",
                "IsReadOnly": "",
                "Enabled": "",
                "OperatingSystem": "",
                "LdapReachable": "",
                "CoreServicesStatus": "",
                "TimeSource": "",
                "FsmoRoles": "",
                "FindingCount": "",
                "HighestSeverity": clean(edge.get("Severity")) or "Info",
                "Status": clean(edge.get("Status")) or "OK",
                "Notes": clean(edge.get("Notes")),
            },
        )
        if severity_rank(edge.get("Severity")) > severity_rank(dcs[host.lower()].get("HighestSeverity")):
            dcs[host.lower()]["HighestSeverity"] = clean(edge.get("Severity"))
            dcs[host.lower()]["Status"] = clean(edge.get("Status"))
    return dcs


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


def card_style(severity):
    severity = clean(severity)
    if severity == "Critical":
        return COLORS["critical_fill"], COLORS["critical_stroke"], "Critical"
    if severity == "Warning":
        return COLORS["warning_fill"], COLORS["warning_stroke"], "Review"
    if severity == "Info":
        return COLORS["ok_fill"], COLORS["ok_stroke"], "OK"
    return COLORS["unknown_fill"], COLORS["unknown_stroke"], "Unknown"


def edge_color(edge):
    if clean(edge.get("Severity")) == "Critical":
        return COLORS["critical_stroke"]
    if clean(edge.get("Severity")) == "Warning":
        return COLORS["warning_stroke"]
    return COLORS.get(clean(edge.get("Relationship")), COLORS["default_edge"])


def marker_defs():
    marker_items = []
    names = ["ServesDomain", "LocatedInSite", "HoldsFsmo", "UsesTimeSource", "HasFinding", "default"]
    for name in names:
        color = COLORS.get(name, COLORS["default_edge"])
        marker_items.append(
            f'<marker id="arrow-{name}" viewBox="0 0 10 10" refX="9" refY="5" '
            f'markerWidth="8" markerHeight="8" orient="auto-start-reverse">'
            f'<path d="M 0 0 L 10 5 L 0 10 z" fill="{color}"/></marker>'
        )
    return "<defs>\n" + "\n".join(marker_items) + "\n</defs>"


def relationship_marker(edge):
    rel = clean(edge.get("Relationship"))
    if rel in {"ServesDomain", "LocatedInSite", "HoldsFsmo", "UsesTimeSource", "HasFinding"}:
        return f"arrow-{rel}"
    return "arrow-default"


def draw_card(x, y, w, h, title, subtitle=None, fill=None, stroke=None, title_size=14):
    fill = fill or COLORS["panel_fill"]
    stroke = stroke or COLORS["panel_stroke"]
    out = [
        f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="8" fill="{fill}" stroke="{stroke}" stroke-width="1.5"/>',
        svg_text(x + 14, y + 26, split_label(title, 34, 2), size=title_size, weight="700"),
    ]
    if subtitle:
        out.append(svg_text(x + 14, y + h - 18, split_label(subtitle, 48, 2), size=11, fill=COLORS["muted"]))
    return "\n".join(out)


def draw_legend(x, y):
    items = [
        ("Domain", "ServesDomain"),
        ("Site", "LocatedInSite"),
        ("FSMO role", "HoldsFsmo"),
        ("Time source", "UsesTimeSource"),
        ("Finding", "HasFinding"),
    ]
    out = [svg_text(x, y, ["Relationship Legend"], size=14, weight="700")]
    cursor_y = y + 22
    for label, rel in items:
        color = COLORS[rel]
        out.append(f'<line x1="{x}" y1="{cursor_y}" x2="{x + 34}" y2="{cursor_y}" stroke="{color}" stroke-width="3"/>')
        out.append(svg_text(x + 44, cursor_y + 4, [label], size=12, fill=COLORS["muted"]))
        cursor_y += 22
    return "\n".join(out)


def draw_combined_svg(inventory):
    edges = normalized_edges(inventory)
    dcs = normalized_dcs(inventory, edges)

    site_groups = defaultdict(list)
    for dc in dcs.values():
        site_groups[clean(dc.get("SiteName")) or "Unknown Site"].append(dc)
    for site in site_groups:
        site_groups[site].sort(key=lambda item: item["HostName"].lower())

    target_items = {}
    for edge in edges:
        target = clean(edge.get("Target"))
        target_type = clean(edge.get("TargetType")) or "Target"
        if not target:
            continue
        key = f"{target_type}|{target}".lower()
        existing = target_items.get(key)
        severity = clean(edge.get("Severity")) or "Info"
        if not existing or severity_rank(severity) > severity_rank(existing.get("Severity")):
            target_items[key] = {
                "Target": target,
                "TargetType": target_type,
                "Relationship": clean(edge.get("Relationship")),
                "Severity": severity,
                "Status": clean(edge.get("Status")),
                "Notes": clean(edge.get("Notes")),
            }

    targets_by_type = defaultdict(list)
    for item in target_items.values():
        targets_by_type[item["TargetType"]].append(item)
    for target_type in targets_by_type:
        targets_by_type[target_type].sort(key=lambda item: item["Target"].lower())

    width = 1850
    margin = 56
    title_h = 124
    dc_x = 76
    dc_w = 470
    target_x = 1210
    target_w = 500
    card_h = 82
    card_gap = 18
    group_gap = 34
    dc_positions = {}
    target_positions = {}

    y = title_h
    site_blocks = []
    for site in sorted(site_groups.keys()):
        items = site_groups[site]
        group_h = 50 + len(items) * card_h + max(0, len(items) - 1) * card_gap + 24
        site_blocks.append((site, y, group_h, items))
        cursor = y + 52
        for dc in items:
            dc_positions[dc["HostName"].lower()] = {"x": dc_x, "y": cursor, "w": dc_w, "h": card_h}
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
        svg_text(margin, 50, ["Domain Controller Health - Combined View"], size=30, weight="800"),
        svg_text(margin, 78, ["DC, site, domain, FSMO, time-source, and finding relationships. Edge IDs map to dc-health-relationship-details.csv."], size=14, fill=COLORS["muted"]),
        draw_legend(1370, 38),
    ]

    for site, block_y, block_h, items in site_blocks:
        out.append(
            f'<rect x="{dc_x - 20}" y="{block_y}" width="{dc_w + 40}" height="{block_h}" rx="10" '
            f'fill="{COLORS["panel_fill"]}" stroke="{COLORS["panel_stroke"]}" stroke-width="1.5"/>'
        )
        out.append(svg_text(dc_x, block_y + 30, [site], size=16, weight="700"))
        for dc in items:
            pos = dc_positions[dc["HostName"].lower()]
            fill, stroke, label = card_style(dc.get("HighestSeverity"))
            details = f'{label} | LDAP: {dc.get("LdapReachable") or "unknown"} | Services: {dc.get("CoreServicesStatus") or "unknown"}'
            if dc.get("FsmoRoles"):
                details += f' | FSMO: {dc["FsmoRoles"]}'
            out.append(draw_card(pos["x"], pos["y"], pos["w"], pos["h"], dc["HostName"], details, fill, stroke))

    for target_type, block_y, block_h, targets in target_blocks:
        out.append(
            f'<rect x="{target_x - 20}" y="{block_y}" width="{target_w + 40}" height="{block_h}" rx="10" '
            f'fill="{COLORS["panel_fill"]}" stroke="{COLORS["panel_stroke"]}" stroke-width="1.5"/>'
        )
        out.append(svg_text(target_x, block_y + 30, [target_type], size=16, weight="700"))
        for target in targets:
            pos = target_positions[f'{target["TargetType"]}|{target["Target"]}'.lower()]
            fill, stroke, label = card_style(target.get("Severity"))
            subtitle = f'{target.get("Relationship") or "Relationship"} | {label}'
            if target.get("Notes"):
                subtitle += f' | {target["Notes"]}'
            out.append(draw_card(pos["x"], pos["y"], pos["w"], pos["h"], target["Target"], subtitle, fill or COLORS["target_fill"], stroke or COLORS["target_stroke"]))

    label_offsets = defaultdict(int)
    for index, edge in enumerate(edges):
        source = clean(edge.get("Source")).lower()
        target = clean(edge.get("Target"))
        target_type = clean(edge.get("TargetType")) or "Target"
        source_pos = dc_positions.get(source)
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
            f'fill="none" stroke="{color}" stroke-width="2.2" stroke-opacity="0.82" marker-end="url(#{marker})"/>'
        )
        label = edge_id(edge, index)
        out.append(
            f'<rect x="{mid_x - 31}" y="{mid_y - 13}" width="62" height="22" rx="5" '
            f'fill="{COLORS["label_fill"]}" stroke="{color}" stroke-width="1"/>'
        )
        out.append(svg_text(mid_x, mid_y + 4, [label], size=10, weight="700", fill=color, anchor="middle"))

    out.append(svg_text(margin, height - 28, [f"{len(edges)} domain-controller health relationships rendered."], size=12, fill=COLORS["muted"]))
    out.append("</svg>")
    return "\n".join(out)


def draw_source_svg(inventory):
    edges = normalized_edges(inventory)
    dcs = normalized_dcs(inventory, edges)
    edges_by_dc = defaultdict(list)
    for edge in edges:
        edges_by_dc[clean(edge.get("Source")).lower()].append(edge)

    ordered_dcs = sorted(dcs.values(), key=lambda item: (clean(item.get("SiteName")).lower(), item["HostName"].lower()))
    width = 1850
    margin = 56
    lane_x = 64
    lane_w = width - 128
    top = 116
    lane_gap = 28
    row_h = 34
    lane_min_h = 190
    y = top
    lanes = []
    for dc in ordered_dcs:
        dc_edges = edges_by_dc.get(dc["HostName"].lower(), [])
        lane_h = max(lane_min_h, 122 + max(1, len(dc_edges)) * row_h + 16)
        lanes.append((dc, dc_edges, y, lane_h))
        y += lane_h + lane_gap
    height = max(y + 44, 640)

    out = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
        marker_defs(),
        f'<rect x="0" y="0" width="{width}" height="{height}" fill="{COLORS["background"]}"/>',
        svg_text(margin, 50, ["Domain Controller Health - Source View"], size=30, weight="800"),
        svg_text(margin, 78, ["One lane per domain controller with role, locator, time-source, and finding relationships."], size=14, fill=COLORS["muted"]),
    ]

    columns = [
        ("ID", 86),
        ("Relationship", 160),
        ("Target", 300),
        ("Type", 170),
        ("Severity", 92),
        ("Status", 120),
        ("Notes", lane_w - 40 - 86 - 160 - 300 - 170 - 92 - 120),
    ]

    for dc, dc_edges, lane_y, lane_h in lanes:
        out.append(
            f'<rect x="{lane_x}" y="{lane_y}" width="{lane_w}" height="{lane_h}" rx="10" '
            f'fill="{COLORS["panel_fill"]}" stroke="{COLORS["panel_stroke"]}" stroke-width="1.5"/>'
        )
        fill, stroke, label = card_style(dc.get("HighestSeverity"))
        subtitle = f'{label} | Site: {dc.get("SiteName") or "Unknown"} | Domain: {dc.get("DomainName") or "Unknown"}'
        out.append(draw_card(lane_x + 20, lane_y + 22, 470, 76, dc["HostName"], subtitle, fill, stroke))
        evidence = f'LDAP: {dc.get("LdapReachable") or "unknown"} | Services: {dc.get("CoreServicesStatus") or "unknown"}'
        if dc.get("TimeSource"):
            evidence += f' | Time: {dc["TimeSource"]}'
        if dc.get("Notes"):
            evidence += f' | {dc["Notes"]}'
        out.append(draw_card(lane_x + 510, lane_y + 22, lane_w - 550, 76, "Readiness Evidence", evidence, COLORS["panel_fill"], COLORS["panel_stroke"], title_size=13))

        header_y = lane_y + 124
        cursor_x = lane_x + 20
        out.append(f'<rect x="{cursor_x}" y="{header_y - 22}" width="{lane_w - 40}" height="30" fill="{COLORS["row_alt"]}" stroke="{COLORS["panel_stroke"]}"/>')
        for title, col_w in columns:
            out.append(svg_text(cursor_x + 8, header_y - 2, [title], size=11, weight="700", fill=COLORS["muted"]))
            cursor_x += col_w

        row_y = header_y + 12
        if not dc_edges:
            out.append(svg_text(lane_x + 28, row_y + 18, ["No diagram relationships were found for this domain controller."], size=12, fill=COLORS["muted"]))
            continue

        for row_index, edge in enumerate(sorted(dc_edges, key=lambda item: (clean(item.get("Relationship")), clean(item.get("Target"))))):
            fill_row = COLORS["panel_fill"] if row_index % 2 == 0 else COLORS["row_alt"]
            out.append(f'<rect x="{lane_x + 20}" y="{row_y}" width="{lane_w - 40}" height="{row_h}" fill="{fill_row}" stroke="{COLORS["panel_stroke"]}" stroke-width="0.6"/>')
            values = [
                clean(edge.get("DcHealthEdgeId")),
                clean(edge.get("Relationship")),
                clean(edge.get("Target")),
                clean(edge.get("TargetType")),
                clean(edge.get("Severity")),
                clean(edge.get("Status")),
                clean(edge.get("Notes")),
            ]
            cursor_x = lane_x + 20
            for value, (_, col_w) in zip(values, columns):
                out.append(svg_text(cursor_x + 8, row_y + 22, split_label(value, 42, 1), size=11, fill=COLORS["text"]))
                cursor_x += col_w
            row_y += row_h

    out.append("</svg>")
    return "\n".join(out)


def main():
    parser = argparse.ArgumentParser(description="Render AD domain controller health inventory or relationship CSV to SVG.")
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--inventory", help="Path to inventory.json")
    source.add_argument("--csv", help="Path to dc-health-relationship-details.csv")
    parser.add_argument("--output", required=True, help="Path to output SVG")
    parser.add_argument("--view", choices=["combined", "source"], default="combined")
    parser.add_argument("--details-csv", help="Optional path to write dc-health-relationship-details.csv")
    parser.add_argument("--inventory-output", help="Optional path to write inventory.json when input is CSV")
    args = parser.parse_args()

    if args.inventory:
        inventory = read_inventory(args.inventory)
    else:
        inventory = csv_to_inventory(args.csv)
        if args.inventory_output:
            write_inventory(args.inventory_output, inventory)

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
