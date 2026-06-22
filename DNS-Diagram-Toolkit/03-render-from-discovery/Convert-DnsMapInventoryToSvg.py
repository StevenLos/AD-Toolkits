#!/usr/bin/env python3
"""
Render DNS map inventory JSON or dns-relationship-details.csv to standalone SVG.

The renderer is intentionally dependency-light. It supports offline CSV and
discovery-driven workflows:
- CSV -> normalized inventory JSON
- inventory/CSV -> combined SVG
- inventory/CSV -> source SVG
- inventory/CSV -> dns-relationship-details.csv
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
    "DnsEdgeId",
    "Source",
    "SourceType",
    "Relationship",
    "Target",
    "TargetType",
    "ZoneName",
    "RecordType",
    "Direction",
    "SiteName",
    "SubnetName",
    "TargetSiteName",
    "TargetSubnetName",
    "DnsServer",
    "Order",
    "Priority",
    "Status",
    "SourceCollectionServer",
    "Notes",
]

COLORS = {
    "background": "#f8fafc",
    "text": "#0f172a",
    "muted": "#64748b",
    "panel_fill": "#ffffff",
    "panel_stroke": "#cbd5e1",
    "site_fill": "#eef2ff",
    "site_stroke": "#4f46e5",
    "server_fill": "#ecfdf5",
    "server_stroke": "#059669",
    "target_fill": "#fff7ed",
    "target_stroke": "#ea580c",
    "card_fill": "#ffffff",
    "row_alt": "#f1f5f9",
    "label_fill": "#ffffff",
    "HostsZone": "#2563eb",
    "ForwardsTo": "#dc2626",
    "ConditionalForwarder": "#7c3aed",
    "DelegatesTo": "#0891b2",
    "AuthoritativeNS": "#059669",
    "RootHint": "#ea580c",
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


def xml(value):
    return html.escape(str(value or ""), quote=True)


def clean(value):
    return str(value or "").strip()


def read_csv(path):
    with Path(path).open("r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        rows = []
        for row in reader:
            rows.append({field: clean(row.get(field, "")) for field in FIELDS})
        return rows


def write_csv(path, rows):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=FIELDS)
        writer.writeheader()
        for row in rows:
            writer.writerow({field: clean(row.get(field, "")) for field in FIELDS})


def unique_by(items, key_func):
    seen = set()
    result = []
    for item in items:
        key = clean(key_func(item)).lower()
        if not key or key in seen:
            continue
        seen.add(key)
        result.append(item)
    return result


def edge_id(row, index):
    existing = clean(row.get("DnsEdgeId"))
    if existing:
        return existing
    return f"D{index + 1:02d}"


def edge_color(edge):
    return COLORS.get(clean(edge.get("Relationship")), COLORS["default_edge"])


def split_label(text, width=32, max_lines=4):
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


def relationship_label(edge):
    rel = clean(edge.get("Relationship")) or "Relationship"
    zone = clean(edge.get("ZoneName"))
    record = clean(edge.get("RecordType"))
    parts = [rel]
    if zone:
        parts.append(zone)
    if record:
        parts.append(record)
    return " | ".join(parts)


def source_anchor(edge):
    dns_server = clean(edge.get("DnsServer"))
    source = clean(edge.get("Source"))
    source_type = clean(edge.get("SourceType"))
    if dns_server:
        return dns_server
    if source_type.lower() == "dnsserver":
        return source
    return source or "Unknown source"


def csv_to_inventory(path):
    rows = read_csv(path)
    now = datetime.now(timezone.utc).isoformat()

    server_items = []
    site_items = []
    subnet_items = []
    zone_items = []
    forwarders = []
    conditional_forwarders = []
    delegations = []
    name_servers = []
    root_hints = []

    for row in rows:
        source = clean(row.get("Source"))
        target = clean(row.get("Target"))
        source_type = clean(row.get("SourceType"))
        target_type = clean(row.get("TargetType"))
        relationship = clean(row.get("Relationship"))
        dns_server = source_anchor(row)
        site_name = clean(row.get("SiteName")) or "Unknown"
        subnet_name = clean(row.get("SubnetName"))

        if dns_server:
            server_items.append(
                {
                    "Name": dns_server,
                    "SiteName": site_name,
                    "SubnetName": subnet_name,
                    "SourceCollectionServer": clean(row.get("SourceCollectionServer")),
                }
            )
        if source_type.lower() == "dnsserver" and source:
            server_items.append({"Name": source, "SiteName": site_name, "SubnetName": subnet_name})
        if target_type.lower() == "dnsserver" and target:
            server_items.append(
                {
                    "Name": target,
                    "SiteName": clean(row.get("TargetSiteName")) or "Unknown",
                    "SubnetName": clean(row.get("TargetSubnetName")),
                }
            )

        for site_field in ("SiteName", "TargetSiteName"):
            site = clean(row.get(site_field))
            if site:
                site_items.append({"SiteName": site})
        for subnet_field in ("SubnetName", "TargetSubnetName"):
            subnet = clean(row.get(subnet_field))
            if subnet:
                subnet_items.append({"SubnetName": subnet})

        zone_name = clean(row.get("ZoneName"))
        if zone_name:
            zone_items.append({"ZoneName": zone_name, "DnsServer": dns_server, "SiteName": site_name})
        if source_type.lower() == "dnszone" and source:
            zone_items.append({"ZoneName": source, "DnsServer": dns_server, "SiteName": site_name})
        if target_type.lower() == "dnszone" and target:
            zone_items.append({"ZoneName": target, "DnsServer": dns_server, "SiteName": site_name})

        item = {
            "DnsEdgeId": clean(row.get("DnsEdgeId")),
            "DnsServer": dns_server,
            "Source": source,
            "Target": target,
            "ZoneName": zone_name,
            "Order": clean(row.get("Order")),
            "Priority": clean(row.get("Priority")),
            "SiteName": site_name,
            "Notes": clean(row.get("Notes")),
        }
        if relationship == "ForwardsTo":
            forwarders.append(item)
        elif relationship == "ConditionalForwarder":
            conditional_forwarders.append(item)
        elif relationship == "DelegatesTo":
            delegations.append(item)
        elif relationship == "AuthoritativeNS":
            name_servers.append(item)
        elif relationship == "RootHint":
            root_hints.append(item)

    return {
        "Metadata": {
            "Source": "DnsRelationshipCsv",
            "InputFile": str(path),
            "GeneratedAtUtc": now,
        },
        "CollectionFiles": [],
        "DnsServers": unique_by(server_items, lambda item: item.get("Name")),
        "ADSites": unique_by(site_items, lambda item: item.get("SiteName")),
        "ADSubnets": unique_by(subnet_items, lambda item: item.get("SubnetName")),
        "ADSiteLinks": [],
        "DomainControllers": [],
        "Zones": unique_by(zone_items, lambda item: f'{item.get("DnsServer")}|{item.get("ZoneName")}'),
        "Records": [],
        "Forwarders": forwarders,
        "ConditionalForwarders": conditional_forwarders,
        "Delegations": delegations,
        "NameServers": name_servers,
        "RootHints": root_hints,
        "DnsEdges": rows,
    }


def load_inventory(path):
    with Path(path).open("r", encoding="utf-8-sig") as handle:
        return json.load(handle)


def save_inventory(path, inventory):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(inventory, indent=2), encoding="utf-8")


def normalized_edges(inventory):
    edges = []
    for index, edge in enumerate(as_list(inventory.get("DnsEdges"))):
        row = {field: clean(edge.get(field, "")) for field in FIELDS}
        row["DnsEdgeId"] = edge_id(row, index)
        edges.append(row)
    return edges


def server_lookup(inventory, edges):
    servers = {}
    for server in as_list(inventory.get("DnsServers")):
        name = clean(server.get("Name") or server.get("HostName") or server.get("DnsServer"))
        if not name:
            continue
        servers[name.lower()] = {
            "Name": name,
            "SiteName": clean(server.get("SiteName")) or "Unknown",
            "SubnetName": clean(server.get("SubnetName")),
            "Notes": clean(server.get("Notes")),
        }

    for edge in edges:
        name = source_anchor(edge)
        if not name:
            continue
        servers.setdefault(
            name.lower(),
            {
                "Name": name,
                "SiteName": clean(edge.get("SiteName")) or "Unknown",
                "SubnetName": clean(edge.get("SubnetName")),
                "Notes": "",
            },
        )
    return servers


def marker_defs():
    marker_items = []
    for relationship, color in COLORS.items():
        if relationship not in {"HostsZone", "ForwardsTo", "ConditionalForwarder", "DelegatesTo", "AuthoritativeNS", "RootHint"}:
            continue
        marker_items.append(
            f'<marker id="arrow-{relationship}" viewBox="0 0 10 10" refX="9" refY="5" '
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
    if rel in {"HostsZone", "ForwardsTo", "ConditionalForwarder", "DelegatesTo", "AuthoritativeNS", "RootHint"}:
        return f"arrow-{rel}"
    return "arrow-default"


def draw_card(x, y, w, h, title, subtitle=None, fill=None, stroke=None, title_size=14):
    fill = fill or COLORS["card_fill"]
    stroke = stroke or COLORS["panel_stroke"]
    out = [
        f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="8" fill="{fill}" stroke="{stroke}" stroke-width="1.5"/>',
        svg_text(x + 14, y + 26, split_label(title, 28, 2), size=title_size, weight="700"),
    ]
    if subtitle:
        out.append(svg_text(x + 14, y + h - 18, split_label(subtitle, 44, 2), size=11, fill=COLORS["muted"]))
    return "\n".join(out)


def draw_legend(x, y):
    items = [
        ("Hosts zone", "HostsZone"),
        ("Forwards to", "ForwardsTo"),
        ("Conditional forwarder", "ConditionalForwarder"),
        ("Delegation", "DelegatesTo"),
        ("Authoritative NS", "AuthoritativeNS"),
        ("Root hint", "RootHint"),
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
    servers = server_lookup(inventory, edges)

    site_groups = defaultdict(list)
    for server in servers.values():
        site_groups[server.get("SiteName") or "Unknown"].append(server)
    for site in site_groups:
        site_groups[site].sort(key=lambda item: item["Name"].lower())

    target_items = {}
    for edge in edges:
        target = clean(edge.get("Target")) or clean(edge.get("ZoneName")) or "Unknown target"
        target_type = clean(edge.get("TargetType")) or "Target"
        key = f"{target_type}|{target}".lower()
        target_items.setdefault(
            key,
            {
                "Name": target,
                "TargetType": target_type,
                "Relationship": clean(edge.get("Relationship")),
                "ZoneName": clean(edge.get("ZoneName")),
            },
        )

    targets_by_type = defaultdict(list)
    for target in target_items.values():
        targets_by_type[target.get("TargetType") or "Target"].append(target)
    for target_type in targets_by_type:
        targets_by_type[target_type].sort(key=lambda item: item["Name"].lower())

    margin = 56
    width = 1800
    title_h = 114
    server_x = 76
    server_w = 400
    target_x = 1180
    target_w = 500
    card_h = 72
    card_gap = 18
    group_gap = 34
    target_gap = 16
    server_positions = {}
    target_positions = {}

    y = title_h
    site_blocks = []
    for site in sorted(site_groups.keys(), key=lambda value: (value in {"Unknown", "Ambiguous"}, value.lower())):
        servers_in_site = site_groups[site]
        group_h = 50 + len(servers_in_site) * card_h + max(0, len(servers_in_site) - 1) * card_gap + 24
        site_blocks.append((site, y, group_h, servers_in_site))
        cursor = y + 52
        for server in servers_in_site:
            server_positions[server["Name"].lower()] = {
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
        group_h = 50 + len(targets) * card_h + max(0, len(targets) - 1) * target_gap + 24
        target_blocks.append((target_type, y, group_h, targets))
        cursor = y + 52
        for target in targets:
            target_positions[f'{target["TargetType"]}|{target["Name"]}'.lower()] = {
                "x": target_x,
                "y": cursor,
                "w": target_w,
                "h": card_h,
            }
            cursor += card_h + target_gap
        y += group_h + group_gap
    right_height = y

    height = max(left_height, right_height, 720) + 80
    out = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
        marker_defs(),
        f'<rect x="0" y="0" width="{width}" height="{height}" fill="{COLORS["background"]}"/>',
        svg_text(margin, 50, ["DNS Map - Combined View"], size=30, weight="800"),
        svg_text(
            margin,
            78,
            ["High-level DNS topology. Edge IDs map to dns-relationship-details.csv."],
            size=14,
            fill=COLORS["muted"],
        ),
        draw_legend(1320, 38),
    ]

    for site, block_y, block_h, servers_in_site in site_blocks:
        out.append(
            f'<rect x="{server_x - 20}" y="{block_y}" width="{server_w + 40}" height="{block_h}" rx="10" '
            f'fill="{COLORS["site_fill"]}" stroke="{COLORS["site_stroke"]}" stroke-width="1.5"/>'
        )
        out.append(svg_text(server_x, block_y + 30, [f"AD Site: {site}"], size=16, weight="700", fill=COLORS["site_stroke"]))
        for server in servers_in_site:
            pos = server_positions[server["Name"].lower()]
            subtitle = "Subnet: " + server["SubnetName"] if server.get("SubnetName") else "DNS server"
            out.append(draw_card(pos["x"], pos["y"], pos["w"], pos["h"], server["Name"], subtitle, COLORS["server_fill"], COLORS["server_stroke"]))

    for target_type, block_y, block_h, targets in target_blocks:
        out.append(
            f'<rect x="{target_x - 20}" y="{block_y}" width="{target_w + 40}" height="{block_h}" rx="10" '
            f'fill="{COLORS["panel_fill"]}" stroke="{COLORS["panel_stroke"]}" stroke-width="1.5"/>'
        )
        out.append(svg_text(target_x, block_y + 30, [target_type], size=16, weight="700"))
        for target in targets:
            pos = target_positions[f'{target["TargetType"]}|{target["Name"]}'.lower()]
            subtitle = relationship_label({"Relationship": target.get("Relationship"), "ZoneName": target.get("ZoneName")})
            out.append(draw_card(pos["x"], pos["y"], pos["w"], pos["h"], target["Name"], subtitle, COLORS["target_fill"], COLORS["target_stroke"]))

    label_offsets = defaultdict(int)
    for index, edge in enumerate(edges):
        source = source_anchor(edge).lower()
        target = clean(edge.get("Target")) or clean(edge.get("ZoneName")) or "Unknown target"
        target_type = clean(edge.get("TargetType")) or "Target"
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
            f'fill="none" stroke="{color}" stroke-width="2.2" stroke-opacity="0.78" marker-end="url(#{marker})"/>'
        )
        edge_label = edge_id(edge, index)
        out.append(
            f'<rect x="{mid_x - 22}" y="{mid_y - 13}" width="44" height="22" rx="5" '
            f'fill="{COLORS["label_fill"]}" stroke="{color}" stroke-width="1"/>'
        )
        out.append(svg_text(mid_x, mid_y + 4, [edge_label], size=11, weight="700", fill=color, anchor="middle"))

    out.append(svg_text(margin, height - 28, [f"{len(edges)} DNS relationships rendered. Detailed DNS records are intentionally kept in JSON/CSV, not the diagram."], size=12, fill=COLORS["muted"]))
    out.append("</svg>")
    return "\n".join(out)


def draw_source_svg(inventory):
    edges = normalized_edges(inventory)
    servers = server_lookup(inventory, edges)
    edges_by_server = defaultdict(list)
    for edge in edges:
        edges_by_server[source_anchor(edge).lower()].append(edge)

    ordered_servers = sorted(servers.values(), key=lambda item: ((item.get("SiteName") or "Unknown").lower(), item["Name"].lower()))
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
        server_edges = edges_by_server.get(server["Name"].lower(), [])
        lane_h = max(lane_min_h, 116 + max(1, len(server_edges)) * row_h)
        lanes.append((server, server_edges, y, lane_h))
        y += lane_h + lane_gap
    height = max(y + 44, 640)

    out = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
        marker_defs(),
        f'<rect x="0" y="0" width="{width}" height="{height}" fill="{COLORS["background"]}"/>',
        svg_text(margin, 50, ["DNS Map - Source View"], size=30, weight="800"),
        svg_text(margin, 78, ["One lane per DNS server with hosted zones and forwarding relationships."], size=14, fill=COLORS["muted"]),
    ]

    columns = [
        ("ID", 70),
        ("Relationship", 180),
        ("Target", 340),
        ("Zone", 260),
        ("Record", 88),
        ("Status", 110),
        ("Notes", lane_w - 70 - 180 - 340 - 260 - 88 - 110 - 210),
    ]

    for server, server_edges, lane_y, lane_h in lanes:
        out.append(
            f'<rect x="{lane_x}" y="{lane_y}" width="{lane_w}" height="{lane_h}" rx="10" '
            f'fill="{COLORS["panel_fill"]}" stroke="{COLORS["panel_stroke"]}" stroke-width="1.5"/>'
        )
        out.append(draw_card(lane_x + 20, lane_y + 22, 390, 76, server["Name"], f'Site: {server.get("SiteName") or "Unknown"} | Subnet: {server.get("SubnetName") or ""}', COLORS["server_fill"], COLORS["server_stroke"]))
        summary = defaultdict(int)
        for edge in server_edges:
            summary[clean(edge.get("Relationship")) or "Relationship"] += 1
        summary_text = ", ".join(f"{key}: {summary[key]}" for key in sorted(summary)) or "No relationships"
        out.append(draw_card(lane_x + 430, lane_y + 22, lane_w - 470, 76, "Relationship Summary", summary_text, COLORS["card_fill"], COLORS["panel_stroke"], title_size=13))

        header_y = lane_y + 122
        cursor_x = lane_x + 20
        out.append(f'<rect x="{cursor_x}" y="{header_y - 22}" width="{lane_w - 40}" height="30" fill="{COLORS["row_alt"]}" stroke="{COLORS["panel_stroke"]}"/>')
        for title, col_w in columns:
            out.append(svg_text(cursor_x + 8, header_y - 2, [title], size=11, weight="700", fill=COLORS["muted"]))
            cursor_x += col_w

        row_y = header_y + 12
        if not server_edges:
            out.append(svg_text(lane_x + 28, row_y + 18, ["No DNS relationships were found for this server."], size=12, fill=COLORS["muted"]))
            continue

        for row_index, edge in enumerate(sorted(server_edges, key=lambda item: (clean(item.get("Relationship")), clean(item.get("ZoneName")), clean(item.get("Target"))))):
            fill = COLORS["card_fill"] if row_index % 2 == 0 else COLORS["row_alt"]
            out.append(f'<rect x="{lane_x + 20}" y="{row_y}" width="{lane_w - 40}" height="{row_h}" fill="{fill}" stroke="{COLORS["panel_stroke"]}" stroke-width="0.6"/>')
            values = [
                edge.get("DnsEdgeId"),
                edge.get("Relationship"),
                edge.get("Target"),
                edge.get("ZoneName"),
                edge.get("RecordType"),
                edge.get("Status"),
                edge.get("Notes"),
            ]
            cursor_x = lane_x + 20
            for (title, col_w), value in zip(columns, values):
                out.append(svg_text(cursor_x + 8, row_y + 21, split_label(value, max(8, int(col_w / 7)), 1), size=11))
                cursor_x += col_w
            row_y += row_h

    out.append("</svg>")
    return "\n".join(out)


def parse_args():
    parser = argparse.ArgumentParser(description="Render DNS map inventory JSON or CSV to SVG.")
    input_group = parser.add_mutually_exclusive_group(required=True)
    input_group.add_argument("-i", "--inventory", help="Path to inventory.json")
    input_group.add_argument("--dns-csv", help="Path to dns-relationship-details.csv")
    parser.add_argument("-o", "--output", required=True, help="Path to output SVG")
    parser.add_argument("--view", choices=["combined", "source"], default="combined", help="Diagram view to render")
    parser.add_argument("--details-csv", help="Optional path to write normalized DNS relationship details CSV")
    parser.add_argument("--inventory-output", help="Optional path to write normalized inventory JSON when using --dns-csv")
    return parser.parse_args()


def main():
    args = parse_args()
    if args.dns_csv:
        inventory = csv_to_inventory(Path(args.dns_csv))
        if args.inventory_output:
            save_inventory(Path(args.inventory_output), inventory)
            print(f"Wrote {args.inventory_output}")
    else:
        inventory = load_inventory(Path(args.inventory))

    if args.view == "source":
        svg = draw_source_svg(inventory)
    else:
        svg = draw_combined_svg(inventory)

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(svg, encoding="utf-8")
    print(f"Wrote {output_path}")

    if args.details_csv:
        write_csv(Path(args.details_csv), normalized_edges(inventory))
        print(f"Wrote {args.details_csv}")


if __name__ == "__main__":
    main()
