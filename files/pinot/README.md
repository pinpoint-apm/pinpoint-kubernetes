# Bundled Pinot definitions

The JSON files under `3.1.1/` are unmodified copies from Pinpoint tag `v3.1.1`,
distributed under the Apache License 2.0 (see the chart's `LICENSE`):

- `uristat/uristat-common/src/main/pinot/`
- `metric-module/metric/src/main/pinot/`
- `exceptiontrace/exceptiontrace-common/src/main/pinot/`
- `inspector-module/inspector-collector/src/main/pinot/`
- `collector/src/main/pinot/` (Heatmap)

Source: https://github.com/pinpoint-apm/pinpoint/tree/v3.1.1

Keep the original files intact. `initialize-pinot.py` applies the configured
Kafka bootstrap servers, Pinot replication and Kafka 3.0 consumer factory in
memory before creating missing tables. It also maps the Heatmap template to the
Collector 3.1.1 topic `heatmap-stat-app-00`. Existing table configs are preserved.
For a new application release, review its definitions, bundle the versioned
files and extend the initialization regression tests before publishing.
