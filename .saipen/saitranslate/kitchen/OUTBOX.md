# OUTBOX

## TR-001: locale surfaces current — no translation drift
- **status:** stale
- **summary:** Core-owned EN/EE/RU/DED and producer-owned locales match the current source surfaces.
- **main_project_refs:** [README.md, docs/KNOWN_LIMITATIONS.md, project.godot]
- **critical:** false
- **producer:** saitranslate
- **source_head:** 44cf3e35fca8000e8a1b06a3ee102f25b197bb69
- **source_tree_fingerprint:** git-delta-v1:594f1818a66f6cc17f8273e563d32d40aafcae5f5c0baeac31982b7b352308a1
- **role_revision:** sha256:7d18729f8d94eb58471ae3bb5fad9151e8499fea291e574b26439c5c89012e41
- **coverage:** shipped docs and real UI strings scanned against current source digest; no new UI string or doc since last build.
- **payload:** []
- **verified:** PASS -- source digest bound to current tree; all locale surfaces carry matching digests; no drift found.
- **instructions:** no integration required; payload [] is intentional. Producer stage satisfied for this crew epoch.
- **details:**
  No translation surface changed in this wave. All shipped docs and UI strings remain bound to the current source identity.

## TR-002: locale surfaces current for release 0.0.1
- **status:** ready
- **summary:** Core-owned EN/EE/RU/DED and producer-owned locales match the current release 0.0.1 source surfaces.
- **main_project_refs:** [README.md, README.ee.md, README.ded.md, README.ja.md, CHANGELOG.md, docs/KNOWN_LIMITATIONS.md, project.godot]
- **critical:** false
- **producer:** saitranslate
- **source_head:** 44cf3e35fca8000e8a1b06a3ee102f25b197bb69
- **source_tree_fingerprint:** git-delta-v1:594f1818a66f6cc17f8273e563d32d40aafcae5f5c0baeac31982b7b352308a1
- **role_revision:** sha256:7d18729f8d94eb58471ae3bb5fad9151e8499fea291e574b26439c5c89012e41
- **coverage:** shipped docs and all four README locale surfaces carry the v0.0.1 badge; UI strings unchanged in this wave; payload [] intentional.
- **payload:** []
- **verified:** PASS -- release parity check for 0.0.1 OK; saipen validate CURRENT_PASS; saipen outbox check saitranslate OUTBOX_VALID.
- **instructions:** no integration required; producer stage satisfied for this crew epoch.
- **details:**
  Release 0.0.1 version surface consists of VERSION, CHANGELOG.md and four README mirrors, all carrying a single matching v0.0.1 badge. No translation drift found; no integration payload.
