# AD Trust Sample Pattern Notes

The DNS toolkit is modeled after the AD trust sample located at:

```text
/Users/slos/Library/CloudStorage/OneDrive-WestMonroe/Documents/CodexProjects/DNSMAP/SAMPLE/AD-Trust-Diag
```

## Observed Structure

- `01-discovery/Export-ADTrustCollection.ps1` writes one self-contained `*.collection.json` bundle per source.
- `02-aggregation/Merge-ADTrustCollections.ps1` reads collection JSON files offline and writes normalized output under `output/01-merged-inventory`.
- `03-render-from-discovery/New-ADTrustImagesFromInventory.ps1` calls a dependency-light Python SVG renderer and optionally converts SVGs to PNG with Chrome, Edge, or Chromium.
- `04-render-from-csv/New-ADTrustImagesFromCsv.ps1` renders diagrams from an edited relationship CSV without querying AD again.
- `04-render-from-csv/New-ADTrustFutureStateCsv.ps1` copies the current-state relationship CSV into `input/manual-csv` for editing.
- The renderer supports `combined` and `source` views and writes a details CSV whose IDs map directly to diagram edge labels.

## DNS Adaptation

- Replace trust collection with DNS Server collection, with optional AD Sites context supplied by the sibling AD toolkit.
- Replace `TrustEdges` with `DnsEdges`.
- Replace `TrustId` labels like `T01` with `DnsEdgeId` labels like `D01`.
- Preserve `combined` and `source` view semantics.
- Preserve optional PNG rendering through browser screenshot tooling.
- Preserve CSV round-trip support for future-state diagrams.
