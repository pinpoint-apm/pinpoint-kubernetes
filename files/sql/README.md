# Bundled Pinpoint SQL

Version directories contain unmodified Apache-2.0 schema scripts pinned to
upstream tags v3.1.1 and v4.0.1. `files/schema-manifest-<version>.json` records
source paths and SHA-256 checksums, including the separate 4.x alarm DDL.
The initializer makes table/index creation idempotent and verifies columns;
it does not remove existing data or reset Spring Batch sequences.
