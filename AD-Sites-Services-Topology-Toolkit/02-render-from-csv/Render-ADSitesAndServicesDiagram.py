#!/usr/bin/env python3
"""Render AD Sites and Services diagram CSVs to standalone SVG."""

from __future__ import annotations

import argparse
import csv
import html
import json
import math
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from textwrap import wrap


FOOTNOTE = (
    "Site-link-derived arrows show possible topology relationships from AD configuration. "
    "They do not prove direct network reachability, active replication connections, or current KCC bridgehead selection."
)
REPLICATION_FOOTNOTE = (
    "Replication health rows are read-only evidence from configured connection objects and observed replication metadata. "
    "They are not remediation actions and do not prove network reachability."
)


def read_csv(path: str) -> list[dict[str, str]]:
    if not path or not Path(path).exists():
        return []
    with open(path, newline="", encoding="utf-8-sig") as handle:
        return [{key: (value or "").strip() for key, value in row.items()} for row in csv.DictReader(handle)]


def esc(value: object) -> str:
    return html.escape("" if value is None else str(value), quote=True)


def safe_int(value: str, default: int) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def text_lines(value: str, width: int = 24, max_lines: int = 3) -> list[str]:
    value = " ".join((value or "").split())
    if not value:
        return [""]
    lines: list[str] = []
    for part in value.split("; "):
        lines.extend(wrap(part, width=width) or [""])
    if len(lines) > max_lines:
        return lines[: max_lines - 1] + ["..."]
    return lines


def svg_text(x: float, y: float, lines: list[str], size: int = 14, weight: str = "400", fill: str = "#17202a") -> str:
    out = [f'<text x="{x:.1f}" y="{y:.1f}" font-size="{size}" font-weight="{weight}" fill="{fill}">']
    for index, line in enumerate(lines):
        dy = 0 if index == 0 else size + 4
        out.append(f'<tspan x="{x:.1f}" dy="{dy}">{esc(line)}</tspan>')
    out.append("</text>")
    return "".join(out)


def node_center(row: dict[str, str], count: int, index: int, width: int) -> tuple[float, float]:
    if count == 1:
        return width / 2, 330
    radius_x = max(300, min(520, width / 2 - 210))
    radius_y = 230
    angle = -math.pi / 2 + (2 * math.pi * index / count)
    return width / 2 + radius_x * math.cos(angle), 350 + radius_y * math.sin(angle)


def marker_defs() -> str:
    return """
<defs>
  <marker id="arrow" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
    <path d="M 0 0 L 10 5 L 0 10 z" fill="#4a6272"/>
  </marker>
  <filter id="softShadow" x="-15%" y="-15%" width="130%" height="130%">
    <feDropShadow dx="0" dy="2" stdDeviation="2" flood-color="#1f2a33" flood-opacity="0.16"/>
  </filter>
</defs>
"""


def table_svg(
    title: str,
    columns: list[tuple[str, str, int]],
    rows: list[dict[str, str]],
    y: float,
    width: int,
    max_rows: int | None = None,
) -> tuple[str, float]:
    left = 60
    table_width = width - 120
    shown_rows = rows[:max_rows] if max_rows else rows
    hidden_count = max(0, len(rows) - len(shown_rows))
    out: list[str] = []
    out.append(svg_text(left, y, [title], size=20, weight="700", fill="#163247"))
    y += 18
    out.append(f'<rect x="{left}" y="{y}" width="{table_width}" height="34" fill="#e9eef2" stroke="#c7d1d8"/>')
    x = left
    for _, header, column_width in columns:
        out.append(svg_text(x + 8, y + 22, [header], size=12, weight="700", fill="#263844"))
        x += column_width
        out.append(f'<line x1="{x}" y1="{y}" x2="{x}" y2="{y + 34}" stroke="#c7d1d8"/>')
    y += 34

    for row_index, row in enumerate(shown_rows):
        wrapped_cells: list[list[str]] = []
        for key, _, column_width in columns:
            wrapped_cells.append(text_lines(row.get(key, ""), width=max(10, column_width // 8), max_lines=3))
        row_height = max(30, 18 + max(len(cell) for cell in wrapped_cells) * 16)
        fill = "#ffffff" if row_index % 2 == 0 else "#f7f9fa"
        out.append(f'<rect x="{left}" y="{y}" width="{table_width}" height="{row_height}" fill="{fill}" stroke="#d7e0e6"/>')
        x = left
        for cell, (_, _, column_width) in zip(wrapped_cells, columns):
            out.append(svg_text(x + 8, y + 20, cell, size=12, fill="#24323a"))
            x += column_width
            out.append(f'<line x1="{x}" y1="{y}" x2="{x}" y2="{y + row_height}" stroke="#e1e7eb"/>')
        y += row_height

    if hidden_count:
        out.append(svg_text(left + 8, y + 20, [f"{hidden_count} additional rows omitted from diagram table; see inventory JSON/CSV."], size=12, fill="#5b6b75"))
        y += 30

    return "\n".join(out), y + 34


def build_inventory(
    objects: list[dict[str, str]],
    links: list[dict[str, str]],
    ports: list[dict[str, str]],
    expansion: list[dict[str, str]],
    subnets: list[dict[str, str]],
    replication_connections: list[dict[str, str]],
    replication_partner_metadata: list[dict[str, str]],
    replication_failures: list[dict[str, str]],
    replication_topology: list[dict[str, str]],
    replication_health: list[dict[str, str]],
    title: str,
    subtitle: str,
    dense: bool,
) -> dict[str, object]:
    return {
        "Metadata": {
            "GeneratedUtc": datetime.now(timezone.utc).isoformat(),
            "Title": title,
            "Subtitle": subtitle,
            "DenseRendering": dense,
            "Footnote": FOOTNOTE,
        },
        "Counts": {
            "Sites": len(objects),
            "LineOfSightLinks": len(links),
            "PortRows": len(ports),
            "DomainControllers": len(expansion),
            "Subnets": len(subnets),
            "ReplicationConnections": len(replication_connections),
            "ReplicationPartnerMetadata": len(replication_partner_metadata),
            "ReplicationFailures": len(replication_failures),
            "ReplicationTopologyEdges": len(replication_topology),
            "ReplicationHealthSummary": len(replication_health),
        },
        "ADSites": objects,
        "LineOfSightLinks": links,
        "PortsProtocols": ports,
        "DomainControllers": expansion,
        "ADSubnets": subnets,
        "ReplicationConnections": replication_connections,
        "ReplicationPartnerMetadata": replication_partner_metadata,
        "ReplicationFailures": replication_failures,
        "ReplicationTopologyEdges": replication_topology,
        "ReplicationHealthSummary": replication_health,
    }


def render(args: argparse.Namespace) -> tuple[str, dict[str, object]]:
    objects = sorted(read_csv(args.objects_csv), key=lambda row: (safe_int(row.get("DisplayOrder", ""), 9999), row.get("ObjectName", "")))
    links = sorted(read_csv(args.links_csv), key=lambda row: row.get("LineOfSightId", ""))
    ports = read_csv(args.ports_csv)
    expansion = sorted(read_csv(args.expansion_csv), key=lambda row: (row.get("SiteName", ""), row.get("ServerName", "")))
    subnets = sorted(read_csv(args.subnets_csv), key=lambda row: (row.get("SiteName", ""), row.get("SubnetName", ""))) if args.subnets_csv else []
    replication_connections = sorted(read_csv(args.replication_connections_csv), key=lambda row: (row.get("SourceServer", ""), row.get("DestinationServer", ""), row.get("ConnectionName", "")))
    replication_partner_metadata = sorted(read_csv(args.replication_partner_metadata_csv), key=lambda row: (row.get("SourceServer", ""), row.get("DestinationServer", ""), row.get("NamingContext", "")))
    replication_failures = sorted(read_csv(args.replication_failures_csv), key=lambda row: (row.get("DestinationServer", ""), row.get("SourceServer", ""), row.get("NamingContext", "")))
    replication_topology = sorted(read_csv(args.replication_topology_csv), key=lambda row: row.get("ReplicationEdgeId", ""))
    replication_health = sorted(read_csv(args.replication_health_csv), key=lambda row: (row.get("SiteName", ""), row.get("DomainController", "")))

    dense = len(links) > args.dense_link_threshold or len(objects) > args.dense_site_threshold
    width = max(1280, min(2200, 900 + len(objects) * 110))
    top_height = 690

    dc_counts = Counter(row.get("SiteObjectId", "") for row in expansion)
    subnet_counts = Counter(row.get("SiteObjectId", "") for row in subnets)
    object_by_id = {row["ObjectId"]: row for row in objects}
    centers: dict[str, tuple[float, float]] = {}
    for index, row in enumerate(objects):
        centers[row["ObjectId"]] = node_center(row, len(objects), index, width)

    out: list[str] = []
    out.append(marker_defs())
    out.append(f'<rect x="0" y="0" width="{width}" height="100%" fill="#f5f7f8"/>')
    out.append(svg_text(60, 54, [args.title], size=30, weight="700", fill="#112a3d"))
    out.append(svg_text(60, 86, text_lines(args.subtitle, width=120, max_lines=2), size=15, fill="#4a5c68"))
    out.append(svg_text(60, 122, [FOOTNOTE], size=12, fill="#596b76"))
    out.append(svg_text(60, 140, [REPLICATION_FOOTNOTE], size=12, fill="#596b76"))

    out.append(f'<rect x="40" y="165" width="{width - 80}" height="{top_height - 180}" rx="8" fill="#ffffff" stroke="#cbd6dd"/>')
    out.append(svg_text(60, 198, ["AD Site Topology"], size=20, weight="700", fill="#163247"))

    for link in links:
        source = link.get("SourceObjectId", "")
        target = link.get("TargetObjectId", "")
        if source not in centers or target not in centers:
            continue
        x1, y1 = centers[source]
        x2, y2 = centers[target]
        out.append(
            f'<line x1="{x1:.1f}" y1="{y1:.1f}" x2="{x2:.1f}" y2="{y2:.1f}" '
            'stroke="#4a6272" stroke-width="2.2" marker-start="url(#arrow)" marker-end="url(#arrow)" opacity="0.8"/>'
        )
        if not dense:
            mid_x = (x1 + x2) / 2
            mid_y = (y1 + y2) / 2
            label = link.get("Label", "")
            label_lines = text_lines(label, width=22, max_lines=2)
            label_width = 176
            label_height = 20 + len(label_lines) * 14
            out.append(f'<rect x="{mid_x - label_width / 2:.1f}" y="{mid_y - label_height / 2:.1f}" width="{label_width}" height="{label_height}" rx="5" fill="#ffffff" stroke="#c9d3da" opacity="0.94"/>')
            out.append(svg_text(mid_x - label_width / 2 + 8, mid_y - label_height / 2 + 18, label_lines, size=11, fill="#263844"))

    node_width = 190
    node_height = 92
    for row in objects:
        object_id = row["ObjectId"]
        x, y = centers[object_id]
        left = x - node_width / 2
        top = y - node_height / 2
        out.append(f'<rect x="{left:.1f}" y="{top:.1f}" width="{node_width}" height="{node_height}" rx="7" fill="#edf5f7" stroke="#3d7f8f" stroke-width="2" filter="url(#softShadow)"/>')
        out.append(svg_text(left + 12, top + 24, text_lines(row.get("DisplayLabel") or row.get("ObjectName", ""), width=23, max_lines=2), size=14, weight="700", fill="#123642"))
        detail = f"DCs: {dc_counts[object_id]}   Subnets: {subnet_counts[object_id]}"
        out.append(svg_text(left + 12, top + 67, [detail], size=12, fill="#38515c"))
        if row.get("Location"):
            out.append(svg_text(left + 12, top + 84, text_lines(row["Location"], width=24, max_lines=1), size=11, fill="#5f7078"))

    y = top_height + 35
    link_rows = []
    for link in links:
        source = object_by_id.get(link.get("SourceObjectId", ""), {}).get("ObjectName", link.get("SourceObjectId", ""))
        target = object_by_id.get(link.get("TargetObjectId", ""), {}).get("ObjectName", link.get("TargetObjectId", ""))
        link_rows.append(
            {
                "LineOfSightId": link.get("LineOfSightId", ""),
                "Sites": f"{source} <-> {target}",
                "Label": link.get("Label", ""),
                "Notes": link.get("Notes", ""),
            }
        )
    section, y = table_svg(
        "Site Link Map",
        [
            ("LineOfSightId", "ID", 230),
            ("Sites", "Site Pair", 260),
            ("Label", "Site Link", 240),
            ("Notes", "Notes", width - 120 - 230 - 260 - 240),
        ],
        link_rows,
        y,
        width,
    )
    out.append(section)

    dc_rows = [
        {
            "SiteName": row.get("SiteName", ""),
            "ServerName": row.get("ServerName", ""),
            "IpAddress": row.get("IpAddress", ""),
            "Role": "; ".join(part for part in ["GC" if row.get("IsGlobalCatalog") == "True" else "", "RODC" if row.get("IsReadOnly") == "True" else ""] if part),
            "OperatingSystem": row.get("OperatingSystem", ""),
        }
        for row in expansion
    ]
    section, y = table_svg(
        "Domain Controllers By Site",
        [
            ("SiteName", "Site", 210),
            ("ServerName", "Server", 260),
            ("IpAddress", "IP Address", 190),
            ("Role", "Role", 120),
            ("OperatingSystem", "Operating System", width - 120 - 210 - 260 - 190 - 120),
        ],
        dc_rows,
        y,
        width,
    )
    out.append(section)

    subnet_rows = [
        {
            "SiteName": row.get("SiteName", "") or "Unassigned",
            "SubnetName": row.get("SubnetName", ""),
            "Cidr": row.get("Cidr", ""),
            "Location": row.get("Location", ""),
            "Notes": row.get("Notes", ""),
        }
        for row in subnets
    ]
    section, y = table_svg(
        "AD Site Subnets",
        [
            ("SiteName", "Site", 210),
            ("SubnetName", "Subnet", 210),
            ("Cidr", "CIDR", 170),
            ("Location", "Location", 190),
            ("Notes", "Notes", width - 120 - 210 - 210 - 170 - 190),
        ],
        subnet_rows,
        y,
        width,
    )
    out.append(section)

    if replication_topology:
        replication_rows = [
            {
                "ReplicationEdgeId": row.get("ReplicationEdgeId", ""),
                "EvidenceType": row.get("EvidenceType", ""),
                "Servers": f"{row.get('SourceServer', '')} -> {row.get('DestinationServer', '')}",
                "NamingContext": row.get("NamingContext", ""),
                "Status": row.get("Status", ""),
                "LastSuccess": row.get("LastSuccess", ""),
                "LastFailure": row.get("LastFailure", ""),
                "Notes": row.get("Notes", ""),
            }
            for row in replication_topology
        ]
        section, y = table_svg(
            "Replication Topology Evidence",
            [
                ("ReplicationEdgeId", "ID", 100),
                ("EvidenceType", "Evidence", 190),
                ("Servers", "Source -> Destination", 300),
                ("NamingContext", "Naming Context", 230),
                ("Status", "Status", 110),
                ("LastSuccess", "Last Success", 160),
                ("LastFailure", "Last Failure", 160),
                ("Notes", "Notes", width - 120 - 100 - 190 - 300 - 230 - 110 - 160 - 160),
            ],
            replication_rows,
            y,
            width,
            max_rows=16,
        )
        out.append(section)

    if replication_health:
        section, y = table_svg(
            "Replication Health Summary",
            [
                ("DomainController", "Domain Controller", 250),
                ("SiteName", "Site", 150),
                ("PartnerMetadataCount", "Partners", 80),
                ("ConfiguredConnectionCount", "Configured", 90),
                ("FailureCount", "Failures", 80),
                ("QueueOperationCount", "Queue", 70),
                ("LastSuccess", "Last Success", 170),
                ("LastFailure", "Last Failure", 170),
                ("Status", "Status", 110),
                ("Notes", "Notes", width - 120 - 250 - 150 - 80 - 90 - 80 - 70 - 170 - 170 - 110),
            ],
            replication_health,
            y,
            width,
        )
        out.append(section)

    unique_ports: dict[tuple[str, str, str, str], dict[str, str]] = {}
    for row in ports:
        key = (row.get("Protocol", ""), row.get("Port", ""), row.get("Service", ""), row.get("Purpose", ""))
        unique_ports[key] = {
            "Protocol": key[0],
            "Port": key[1],
            "Service": key[2],
            "Purpose": key[3],
            "AppliesTo": f"{len(links)} site-pair rows",
        }
    port_rows = list(unique_ports.values())
    section, y = table_svg(
        "Ports And Protocols Review Profile",
        [
            ("Protocol", "Protocol", 100),
            ("Port", "Port", 130),
            ("Service", "Service", 220),
            ("Purpose", "Purpose", width - 120 - 100 - 130 - 220 - 160),
            ("AppliesTo", "Applies To", 160),
        ],
        port_rows,
        y,
        width,
    )
    out.append(section)

    out.append(svg_text(60, y, [FOOTNOTE], size=12, fill="#596b76"))
    y += 18
    out.append(svg_text(60, y, [REPLICATION_FOOTNOTE], size=12, fill="#596b76"))
    y += 35

    height = int(y + 35)
    svg = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}" role="img" aria-label="{esc(args.title)}">',
        '<style>text{font-family:Arial,Helvetica,sans-serif;} line{shape-rendering:geometricPrecision;} rect{shape-rendering:geometricPrecision;}</style>',
        "\n".join(out),
        "</svg>",
    ]

    inventory = build_inventory(
        objects,
        links,
        ports,
        expansion,
        subnets,
        replication_connections,
        replication_partner_metadata,
        replication_failures,
        replication_topology,
        replication_health,
        args.title,
        args.subtitle,
        dense,
    )
    return "\n".join(svg), inventory


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Render AD Sites and Services diagram CSVs to SVG.")
    parser.add_argument("--objects-csv", required=True)
    parser.add_argument("--links-csv", required=True)
    parser.add_argument("--ports-csv", required=True)
    parser.add_argument("--expansion-csv", required=True)
    parser.add_argument("--subnets-csv")
    parser.add_argument("--replication-connections-csv")
    parser.add_argument("--replication-partner-metadata-csv")
    parser.add_argument("--replication-failures-csv")
    parser.add_argument("--replication-topology-csv")
    parser.add_argument("--replication-health-csv")
    parser.add_argument("--output", required=True)
    parser.add_argument("--inventory-output", required=True)
    parser.add_argument("--title", default="Active Directory Sites And Services Diagram")
    parser.add_argument("--subtitle", default="AD sites site links domain controllers and supporting network review tables")
    parser.add_argument("--layout-mode", choices=["bipartite", "ring"], default="ring")
    parser.add_argument("--dense-link-threshold", type=int, default=20)
    parser.add_argument("--dense-site-threshold", type=int, default=15)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.layout_mode != "ring":
        raise SystemExit("Only --layout-mode ring is implemented for AD Sites diagrams.")
    svg, inventory = render(args)
    Path(args.output).parent.mkdir(parents=True, exist_ok=True)
    Path(args.inventory_output).parent.mkdir(parents=True, exist_ok=True)
    Path(args.output).write_text(svg, encoding="utf-8")
    Path(args.inventory_output).write_text(json.dumps(inventory, indent=2), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
