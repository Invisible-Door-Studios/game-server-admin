<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk> -->

# Game Server Admin — Wiki

**GSA** is a game-server discovery, configuration-management, and operations tool intended to remain game-neutral. It has protocol probes and a legacy registry covering 18 example profiles and 8 config formats; those examples do not establish a universal lifecycle, config-schema, or server API. A draft JSON config validator and status projection exist only as a fixture-tested slice, not a production integration. See [Probing & Games](04-Probing-and-Games.md) and the [draft profile contract](../developer/GAME-PROFILE-CONTRACT.adoc).

> **Status: `0.9.0`, alpha.** The engine (probing, config extraction, the proven ABI, container ops) is real and tested (167 automated tests). The full GUI stack depends on sibling repos in the wider estate (see [Architecture](02-Architecture.md)), and a handful of v1.0 gates are still open. **Read [Installation](03-Installation.md) and [Troubleshooting](09-Troubleshooting.md) before you expect a one-click experience** — this page is honest about what works today.

```mermaid
flowchart TD
    subgraph GSA["Game Server Admin (this repo)"]
        GUI["Gossamer GUI<br/>Ephapax .eph + 8 HTML panels"]
        FFI["Zig FFI<br/>libgsa.so + gsa CLI"]
        ABI["Idris2 ABI<br/>Types · Foreign · Layout (proven)"]
        GUI --> FFI --> ABI
    end
    subgraph EXT["Estate (sibling repos)"]
        GOSS["Gossamer<br/>webview shell"]
        EPH["Ephapax<br/>language + runtime"]
        VDB["VeriSimDB<br/>8-modality store"]
        GROOVE["Groove<br/>voice/text alerts"]
    end
    GUI -.dlopen.-> GOSS
    GUI -.compiled by.-> EPH
    FFI -->|REST :8090| VDB
    FFI -.->|HTTP alerts| GROOVE
    FFI ==>|probes| TARGETS["Game servers<br/>A2S · Minecraft · RCON · HTTP"]

    classDef ext fill:#f4f4f4,stroke:#999,stroke-dasharray:4 3;
    class GOSS,EPH,VDB,GROOVE ext;
```

GSA is deliberately the **client half** of a multi-repo ecosystem: it *orchestrates* Gossamer, Ephapax, VeriSimDB and Groove but does not contain them. The Zig CLI (`gsa`) works standalone; the GUI needs the estate.

## Start here

| If you want to… | Read |
|---|---|
| Understand what GSA is and how the layers fit | [Architecture](02-Architecture.md) |
| Install and run it | [Installation](03-Installation.md) |
| Probe a server / see supported games | [Probing & Games](04-Probing-and-Games.md) |
| Understand the "proven ABI" (the differentiator) | [The Proven ABI](05-The-Proven-ABI.md) |
| Know how outbound HTTP is governed | [HTTP Capability Gateway](06-HTTP-Capability-Gateway.md) |
| Use the GUI / deploy a new server | [GUI & Nexus Setup](07-GUI-and-Nexus-Setup.md) |
| Run it in containers | [Deployment Topology](08-Deployment-Topology.md) |
| Fix something that's broken | [Troubleshooting](09-Troubleshooting.md) |
| Contribute code | [Contributing](10-Contributing.md) |

## The one-paragraph tour

You give GSA a `host[:port]`. Its **probe engine** ([Probing & Games](04-Probing-and-Games.md)) tries implemented protocols such as A2S (Steam), Minecraft SLP, RCON, HTTP and a raw TCP banner, resolving DNS/IPv6 and honouring a per-probe timeout. Existing profile/container paths can return a legacy A2ML-compatible config representation; profile metadata is not a generic schema validator, and A2ML is not the format for new profiles. Optional storage paths use **VeriSimDB** for config/provenance-oriented records, not authoritative per-tick game state. Every value crossing the Zig↔Idris2 boundary rides a **machine-checked ABI contract** ([The Proven ABI](05-The-Proven-ABI.md)); outbound HTTP uses a **declared capability** with an enforced deadline ([HTTP Capability Gateway](06-HTTP-Capability-Gateway.md)). Server lifecycle and deployment operations remain game-/container-specific, not a universal GSA contract.

## Reference documentation

The wiki is the narrative, illustrated tour. For dense reference material see the developer/maintainer docs (indexed in [`docs/INDEX.adoc`](../INDEX.adoc)):

- [`docs/developer/FFI-MODULE-REFERENCE.adoc`](../developer/FFI-MODULE-REFERENCE.adoc) — every module + exported symbol + the 18 result codes
- [`docs/developer/ARCHITECTURE-RATIONALE.adoc`](../developer/ARCHITECTURE-RATIONALE.adoc) — *why* Ephapax/Idris2/Zig/VeriSimDB
- [`docs/developer/PANEL-EXTENSION-GUIDE.adoc`](../developer/PANEL-EXTENSION-GUIDE.adoc) — add a GUI panel
- [`docs/developer/CONFIG-FORMATS.adoc`](../developer/CONFIG-FORMATS.adoc) — the 8-format parser
- [`docs/maintainer/RELEASE-CHECKLIST.adoc`](../maintainer/RELEASE-CHECKLIST.adoc) · [`CI-CD-GUIDE.adoc`](../maintainer/CI-CD-GUIDE.adoc) · [`SECURITY-SCANNING-RUNBOOK.adoc`](../maintainer/SECURITY-SCANNING-RUNBOOK.adoc)
