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
    ("tag", "realtime"),
    ("double", "realtime"),
    ("dataType", "realtime"),
    ("exceptionTrace", "offline"),
    ("inspector-stat-agent", "realtime"),
    ("inspector-stat-application", "realtime"),
    ("heatmap-stat-application", "realtime"),
    ("heatmap-stat-application", "offline"),
)


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


def load_definitions(directory, bootstrap_servers, replicas):
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


def initialize(controller, definitions):
    for schema, table in definitions:
        schema_name = schema["schemaName"]
        table_name, kind = table["tableName"], table["tableType"]
        ensure_resource(controller, "/schemas/" + quote(schema_name, safe=""),
                        "/schemas?override=false", schema, "schema " + schema_name)
        ensure_resource(controller, "/tables/" + quote(table_name, safe="") + "/state?type=" + kind,
                        "/tables", table, "table " + table_name + "_" + kind)
    print("All required Pinpoint schemas and typed tables exist; verify ingestion separately.", flush=True)


def main():
    try:
        definitions = load_definitions(os.environ["PINOT_DEFINITIONS_DIR"],
                                       os.environ["KAFKA_BOOTSTRAP_SERVERS"],
                                       int(os.environ["PINOT_TABLE_REPLICAS"]))
        initialize(Controller(os.environ["PINOT_CONTROLLER_URL"]), definitions)
    except (InitializationError, KeyError, ValueError) as error:
        print("Pinot initialization failed: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
