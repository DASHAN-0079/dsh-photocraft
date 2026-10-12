# Changes

## 0.2.0 — 2026-10-12

- Add macOS Intel and Apple Silicon using official PhotoCraft 0.7.0 Universal app and CLI packages, both SHA-256 pinned.
- Preserve the signed app bundle, validate code signatures, and remove only FinderInfo/ResourceFork packaging metadata that macOS rejects. Quarantine and other attributes are preserved.
- Resolve installation, executable, and workspace paths by platform. Support paths containing spaces.
- Launch the native desktop on macOS without Windows-only flags, preserving it after MCP disconnects.
- Keep Windows x64 support and existing 0.1.0 runtime receipts/data compatible.
- Verify installation, repeated installation, all 21 MCP tools and 105 integration checks on Windows x64, macOS 15 Intel and macOS 15 Apple Silicon in CI.
- PowerShell 7 is required on both platforms. Linux and Windows ARM64 remain unsupported.

## 0.1.0 — 2026-10-12

- Initial Windows x64 DSH bundle with headless and desktop MCP namespaces.
