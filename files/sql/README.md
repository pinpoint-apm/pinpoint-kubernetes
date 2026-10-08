# Bundled Pinpoint SQL

The files in `3.1.1/` are unmodified Apache-2.0-licensed schema scripts from
`pinpoint-apm/pinpoint` tag `v3.1.1`, under `web/src/main/resources/sql/`.
The upstream license and NOTICE are shipped in `../pinot/NOTICE`.
Bundling these files removes the need for pods to fetch SQL from GitHub during
installation. Add reviewed assets when targeting a different application version.
