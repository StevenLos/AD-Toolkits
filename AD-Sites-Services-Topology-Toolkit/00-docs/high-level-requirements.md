# Active Directory Sites And Services Diagram High-Level Requirements

## Goal

Create a toolkit that can discover Active Directory Sites and Services configuration, export the relevant data, and produce review-ready diagrams and tables.

The first useful artifact is a high-level diagram where visible objects are AD sites and arrows represent AD site-link-derived possible connectivity relationships. Supporting tables must explain domain controllers, subnets, and port/protocol requirements.

## Audience

- Active Directory engineers
- Network and firewall teams
- Infrastructure architects
- Security reviewers
- Migration and integration project teams
- Stakeholders who need a clear view of AD site topology without opening AD Sites and Services

## MVP Scope

- Run offline from mock data.
- Run live read-only discovery when the Active Directory PowerShell module is available.
- Export raw AD inventory to CSV and JSON.
- Convert raw exports to normalized diagram CSVs.
- Render SVG and JSON outputs using the same broad pattern as the sample high-level network diagram project.

## Core Workflow

1. Discover or provide raw AD Sites and Services inventory.
2. Convert raw inventory into normalized diagram CSVs.
3. Run preflight validation.
4. Render the diagram and supporting tables.
5. Review and hand off SVG, CSV, and JSON outputs.

## First Diagram Model

- Nodes: AD sites.
- Links: deduplicated site pairs derived from AD site links, with the original contributing site link names preserved.
- Expansion table: domain controllers per AD site.
- Supporting table: subnets assigned to each AD site.
- Ports/protocols table: configurable AD/DC communication review profile.

## Key Constraints

- Discovery must be read-only.
- Generated IDs must be stable across runs with the same input.
- Raw exports may contain sensitive infrastructure data and must be handled accordingly.
- Site links can contain more than two sites; pairwise expansion is acceptable for MVP only when duplicate/overlapping site pairs are merged and all contributing site link names are preserved.
- AD site links do not prove direct DC-to-DC replication paths. The KCC selects bridgehead topology, and those bridgeheads can change.
- The renderer must use an AD site graph layout for site topology. The existing sample renderer's two-column source/target layout is a reference pattern, not a sufficient layout for AD Sites.
- Transport-level bridge-all-site-links behavior must be captured or clearly caveated because it changes how site-link-derived reachability is interpreted.
- Firewall ports cannot be inferred perfectly from AD metadata, so generated port rows must be treated as review inputs.

## Open Decisions

1. Whether subnets appear visually in the SVG or remain supporting table/JSON data.
2. Whether multi-site links should later render as hub/link objects instead of deduplicated pairwise lines.
3. Whether the default port profile should be broad or minimal.
4. Whether replication health belongs in the first live discovery script.
5. Whether PNG export is needed after SVG is stable.
