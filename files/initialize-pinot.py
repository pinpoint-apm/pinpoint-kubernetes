"""Create missing Pinpoint schemas/tables without replacing existing data/config.

Uses the Pinot 1.3 controller JSON API and only Python's standard library.
HTTP error bodies and configuration contents are deliberately not logged.
"""

import copy
import json
import os
from pathlib import Path
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen


DEFINITIONS = (
    ("uriStat", "realtime"),
    ("uriStat", "offline"),
    ("tag", "realtime"),
    ("double", "realtime"),
    ("double", "offline"),
    ("dataType", "realtime"),
    ("exceptionTrace", "offline"),
    ("exceptionTrace", "realtime"),
    ("otlpmetric-double", "realtime"),
    ("otlpmetric-double", "offline"),
    ("otlpmetric-long", "realtime"),
    ("otlpmetric-long", "offline"),
    ("otlpmetric-metadata", "realtime"),
    ("inspector-stat-agent", "realtime"),
    ("inspector-stat-agent", "offline"),
    ("inspector-stat-application", "realtime"),
    ("heatmap-stat-application", "realtime"),
    ("heatmap-stat-application", "offline"),
)

METADATA_TABLES = frozenset(("otlpMetricMetadata", "systemMetricDataType", "systemMetricTag"))


def retention_settings(environ):
    flags = [environ.get(key, "false") for key in
             ("PINPOINT_RETENTION_ENABLED", "PINPOINT_RETENTION_APPLY_TO_EXISTING")]
    value = environ.get("PINPOINT_RETENTION_DAYS", "7")
    if any(flag not in ("true", "false") for flag in flags):
        raise InitializationError("Retention flags must be true or false")
    if not value.isascii() or not value.isdecimal() or not 1 <= int(value) <= 3650:
        raise InitializationError("Retention days must be an integer from 1 to 3650")
    enabled, apply_existing = (flag == "true" for flag in flags)
    if apply_existing and not enabled:
        raise InitializationError("Applying retention to existing tables requires retention enabled")
    return (int(value) if enabled else None), apply_existing


class InitializationError(RuntimeError):
    pass


class Controller:
    def __init__(self, url):
        self.url = url.rstrip("/")

    def request(self, method, path, payload=None):
        data = None if payload is None else json.dumps(payload).encode()
        request = Request(self.url + path, data=data, method=method,
                          headers={"Content-Type": "application/json"})
        # Retry reads while the controller becomes ready. Never retry writes
        # blindly: a later hook retry first checks the resource again.
        attempts = 6 if method == "GET" else 1
        for attempt in range(attempts):
            try:
                with urlopen(request, timeout=15) as response:
                    status, body = response.status, response.read()
            except HTTPError as error:
                status, body = error.code, b""
            except (URLError, TimeoutError):
                status, body = 503, b""
            if status < 500 or attempt == attempts - 1:
                if 200 <= status < 300:
                    try:
                        return status, json.loads(body)
                    except (ValueError, UnicodeError):
                        raise InitializationError("Controller returned invalid JSON") from None
                return status, None
            time.sleep(5)


def load_definitions(directory, bootstrap_servers, replicas, retention_days=None):
    if not bootstrap_servers or replicas < 1:
        raise InitializationError("Kafka bootstrap servers and positive Pinot replicas are required")
    definitions = []
    for name, kind in DEFINITIONS:
        prefix = Path(directory) / ("pinot-" + name)
        try:
            schema = json.loads(Path(str(prefix) + "-schema.json").read_text())
            table = json.loads(Path(str(prefix) + "-" + kind + "-table.json").read_text())
            table = copy.deepcopy(table)
            table_name = table["tableName"]
            if (not isinstance(table_name, str) or not table_name
                    or schema["schemaName"] != table_name
                    or schema["schemaName"] != table["segmentsConfig"]["schemaName"]
                    or table["tableType"] != kind.upper()):
                raise ValueError()
            segments = table["segmentsConfig"]
            if retention_days is not None and table_name not in METADATA_TABLES:
                segments["retentionTimeUnit"] = "DAYS"
                segments["retentionTimeValue"] = str(retention_days)
            segments["replicasPerPartition"] = str(replicas)
            if kind == "offline":
                segments["replication"] = str(replicas)
            else:
                stream = table["tableIndexConfig"]["streamConfigs"]
                stream["stream.kafka.broker.list"] = bootstrap_servers
                # The upstream Heatmap template uses an old topic name.
                # Collector 3.1.1 produces to heatmap-stat-app-00.
                if name == "heatmap-stat-application":
                    stream["stream.kafka.topic.name"] = "heatmap-stat-app-00"
                # Pinpoint's templates still name the Kafka 2.0 plugin.
                # Pinot 1.3 uses the Kafka 3.0 consumer plugin.
                stream["stream.kafka.consumer.factory.class.name"] = (
                    "org.apache.pinot.plugin.stream.kafka30.KafkaConsumerFactory")
        except (OSError, ValueError, KeyError, TypeError):
            raise InitializationError("Missing or invalid Pinot definition: " + name) from None
        definitions.append((schema, table))
    return definitions


def ensure_resource(controller, lookup, create, payload, label):
    status, _ = controller.request("GET", lookup)
    if status == 200:
        print("Already exists: " + label, flush=True)
        return
    if status != 404:
        raise InitializationError("Cannot check " + label + ": HTTP " + str(status))
    status, _ = controller.request("POST", create, payload)
    if status == 409:
        # Another initializer may have created the resource concurrently.
        status, _ = controller.request("GET", lookup)
    if not 200 <= status < 300:
        raise InitializationError("Cannot create " + label + ": HTTP " + str(status))
    # A successful response must also result in an addressable resource.
    status, _ = controller.request("GET", lookup)
    if status != 200:
        raise InitializationError("Cannot verify " + label + ": HTTP " + str(status))
    print("Created: " + label, flush=True)


def read_table_config(controller, name, kind):
    status, payload = controller.request("GET", "/tables/" + quote(name, safe="") + "?type=" + kind)
    if status != 200:
        raise InitializationError("Cannot read table retention: " + name + "_" + kind + ": HTTP " + str(status))
    config = payload.get(kind) if isinstance(payload, dict) else None
    if (not isinstance(config, dict) or config.get("tableType") != kind
            or config.get("tableName") not in (name, name + "_" + kind)
            or not isinstance(config.get("segmentsConfig"), dict)):
        raise InitializationError("Invalid table configuration for " + name + "_" + kind)
    return config


def reconcile_retention(controller, definitions, days):
    targets = [(table["tableName"], table["tableType"]) for _, table in definitions
               if table["tableName"] not in METADATA_TABLES]
    # Fail on inaccessible/invalid targets before changing any retention config.
    for name, kind in targets:
        read_table_config(controller, name, kind)
    for name, kind in targets:
        config = copy.deepcopy(read_table_config(controller, name, kind))
        segments = config["segmentsConfig"]
        if (segments.get("retentionTimeUnit") == "DAYS"
                and str(segments.get("retentionTimeValue")) == str(days)):
            continue
        segments["retentionTimeUnit"], segments["retentionTimeValue"] = "DAYS", str(days)
        status, _ = controller.request("PUT", "/tables/" + quote(name, safe=""), config)
        if not 200 <= status < 300:
            raise InitializationError("Cannot update retention for " + name + "_" + kind + ": HTTP " + str(status))
        actual = read_table_config(controller, name, kind)["segmentsConfig"]
        if actual.get("retentionTimeUnit") != "DAYS" or str(actual.get("retentionTimeValue")) != str(days):
            raise InitializationError("Retention verification failed for " + name + "_" + kind)
        print("Applied " + str(days) + "-day retention to " + name + "_" + kind, flush=True)
    print("Verified " + str(days) + "-day Pinot history retention; metadata retention preserved", flush=True)


def initialize(controller, definitions, retention_days=None, apply_to_existing=False):
    if apply_to_existing and retention_days is None:
        raise InitializationError("Applying retention to existing tables requires retention enabled")
    for schema, table in definitions:
        schema_name = schema["schemaName"]
        table_name, kind = table["tableName"], table["tableType"]
        ensure_resource(controller, "/schemas/" + quote(schema_name, safe=""),
                        "/schemas?override=false", schema, "schema " + schema_name)
        ensure_resource(controller, "/tables/" + quote(table_name, safe="") + "/state?type=" + kind,
                        "/tables", table, "table " + table_name + "_" + kind)
    if apply_to_existing:
        reconcile_retention(controller, definitions, retention_days)
    print("All required Pinpoint schemas and typed tables exist; verify ingestion separately.", flush=True)


def main():
    try:
        retention_days, apply_existing = retention_settings(os.environ)
        definitions = load_definitions(os.environ["PINOT_DEFINITIONS_DIR"],
                                       os.environ["KAFKA_BOOTSTRAP_SERVERS"],
                                       int(os.environ["PINOT_TABLE_REPLICAS"]), retention_days)
        initialize(Controller(os.environ["PINOT_CONTROLLER_URL"]), definitions, retention_days, apply_existing)
    except (InitializationError, KeyError, ValueError) as error:
        print("Pinot initialization failed: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
