"""Regression tests for partial initialization, retries and controller failures."""

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import HTTPError, URLError

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("pinot_init", ROOT / "files/initialize-pinot.py")
pinot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pinot)


class FakeController:
    def __init__(self):
        # More than seven unrelated tables must not skip missing Pinpoint ones.
        self.schemas = {"unrelated" + str(i) for i in range(8)}
        self.tables = {"unrelated" + str(i) + "_REALTIME" for i in range(8)}
        self.writes = []
        self.failure = None

    def request(self, method, path, payload=None):
        if self.failure:
            return self.failure, None
        if method == "GET":
            if path.startswith("/schemas/"):
                found = path.split("/")[-1] in self.schemas
            else:
                name = path.split("/")[2] + "_" + path.split("type=")[-1]
                found = name in self.tables
            return (200, {}) if found else (404, None)
        self.writes.append((path, payload))
        if path.startswith("/schemas"):
            self.schemas.add(payload["schemaName"])
        else:
            self.tables.add(payload["tableName"] + "_" + payload["tableType"])
        return 200, {"status": "success"}


class PinotInitializationTests(unittest.TestCase):
    def setUp(self):
        self.definitions = pinot.load_definitions(ROOT / "files/pinot/3.1.1", "kafka.example:9092", 2)

    def run_init(self, controller):
        with contextlib.redirect_stdout(io.StringIO()):
            pinot.initialize(controller, self.definitions)

    def test_partial_install_and_upgrade_preserve_existing_resources(self):
        controller = FakeController()
        controller.schemas.add("inspectorStatApp")
        controller.tables.add("uriStat_REALTIME")
        self.run_init(controller)
        self.assertIn("inspectorStatApp_REALTIME", controller.tables)
        self.assertIn("systemMetricDataType_REALTIME", controller.tables)
        self.assertIn("exceptionTrace_OFFLINE", controller.tables)
        self.assertEqual(len(controller.writes), 18)
        self.assertTrue(all(path != "/schemas" for path, _ in controller.writes))
        before = list(controller.writes)
        self.run_init(controller)
        self.assertEqual(controller.writes, before)
        for _, payload in controller.writes:
            if "tableName" in payload:
                self.assertEqual(payload["segmentsConfig"]["replicasPerPartition"], "2")
                if payload["tableType"] == "OFFLINE":
                    self.assertEqual(payload["segmentsConfig"]["replication"], "2")
                else:
                    stream = payload["tableIndexConfig"]["streamConfigs"]
                    self.assertEqual(stream["stream.kafka.broker.list"], "kafka.example:9092")
                    self.assertIn("kafka30.KafkaConsumerFactory", stream["stream.kafka.consumer.factory.class.name"])

    def test_heatmap_has_both_table_types_and_matches_collector_topic(self):
        heatmap = [table for _, table in self.definitions if table["tableName"] == "heatmapStatApp"]
        self.assertEqual({table["tableType"] for table in heatmap}, {"OFFLINE", "REALTIME"})
        realtime = next(table for table in heatmap if table["tableType"] == "REALTIME")
        self.assertEqual(realtime["tableIndexConfig"]["streamConfigs"]["stream.kafka.topic.name"],
                         "heatmap-stat-app-00")

    def test_upgrade_creates_only_missing_realtime_to_offline_targets(self):
        controller = FakeController()
        for schema, table in self.definitions:
            controller.schemas.add(schema["schemaName"])
            controller.tables.add(table["tableName"] + "_" + table["tableType"])
        missing = {"inspectorStatAgent00_OFFLINE", "uriStat_OFFLINE", "systemMetricDouble_OFFLINE"}
        controller.tables.difference_update(missing)
        self.run_init(controller)
        self.assertEqual(len(controller.writes), 3)
        self.assertEqual({table["tableName"] + "_" + table["tableType"]
                          for _, table in controller.writes}, missing)
        for path, table in controller.writes:
            self.assertEqual(path, "/tables")
            self.assertEqual(table["tableType"], "OFFLINE")
            self.assertEqual(table["segmentsConfig"]["replication"], "2")
            expected_retention = "14" if table["tableName"] == "inspectorStatAgent00" else "56"
            self.assertEqual(table["segmentsConfig"]["retentionTimeValue"], expected_retention)
        for _, realtime in self.definitions:
            if "RealtimeToOfflineSegmentsTask" in realtime.get("task", {}).get("taskTypeConfigsMap", {}):
                self.assertIn(realtime["tableName"] + "_OFFLINE", controller.tables)
        self.run_init(controller)
        self.assertEqual(len(controller.writes), 3)

    def test_offline_table_does_not_hide_missing_realtime_table(self):
        controller = FakeController()
        controller.tables.add("inspectorStatApp_OFFLINE")
        self.run_init(controller)
        self.assertIn("inspectorStatApp_REALTIME", controller.tables)

    def test_access_and_server_errors_are_not_treated_as_missing_tables(self):
        for status in (401, 403, 500, 503):
            with self.subTest(status=status):
                controller = FakeController()
                controller.failure = status
                with self.assertRaisesRegex(pinot.InitializationError, "HTTP " + str(status)):
                    self.run_init(controller)
                self.assertEqual(controller.writes, [])

    def test_failed_write_stops_initialization(self):
        controller = FakeController()
        original = controller.request
        def request(method, path, payload=None):
            return (400, None) if method == "POST" else original(method, path, payload)
        controller.request = request
        with self.assertRaisesRegex(pinot.InitializationError, "HTTP 400"):
            self.run_init(controller)
        self.assertEqual(controller.writes, [])

    def test_conflict_is_only_accepted_if_resource_exists(self):
        controller = FakeController()
        original = controller.request
        def request(method, path, payload=None):
            if method == "POST":
                original(method, path, payload)
                return 409, None
            return original(method, path, payload)
        controller.request = request
        self.run_init(controller)
        controller = FakeController()
        original = controller.request
        controller.request = lambda method, path, payload=None: ((409, None) if method == "POST"
                                                               else original(method, path, payload))
        with self.assertRaisesRegex(pinot.InitializationError, "HTTP 404"):
            self.run_init(controller)

    def test_all_files_are_validated_before_controller_mutations(self):
        with tempfile.TemporaryDirectory() as directory:
            for path in (ROOT / "files/pinot/3.1.1").glob("*.json"):
                Path(directory, path.name).write_bytes(path.read_bytes())
            Path(directory, "pinot-inspector-stat-application-schema.json").write_text("not JSON")
            with self.assertRaisesRegex(pinot.InitializationError, "invalid Pinot definition"):
                pinot.load_definitions(directory, "kafka.example:9092", 1)

    def test_http_auth_errors_do_not_disclose_response_bodies(self):
        secret = "sensitive-password"
        error = HTTPError("http://pinot/schemas", 401, secret, {}, io.BytesIO(secret.encode()))
        with patch.object(pinot, "urlopen", side_effect=error):
            self.assertEqual(pinot.Controller("http://pinot").request("GET", "/schemas"), (401, None))

    def test_http_client_posts_json_to_the_configured_controller(self):
        class Response:
            status = 200
            def __enter__(self):
                return self
            def __exit__(self, *args):
                pass
            def read(self):
                return b'{"status":"success"}'
        payload = {"schemaName": "inspectorStatApp"}
        with patch.object(pinot, "urlopen", return_value=Response()) as send:
            result = pinot.Controller("http://custom-controller:9000/").request(
                "POST", "/schemas?override=false", payload)
            self.assertEqual(result, (200, {"status": "success"}))
            request = send.call_args.args[0]
            self.assertEqual(request.full_url, "http://custom-controller:9000/schemas?override=false")
            self.assertEqual(request.method, "POST")
            self.assertEqual(request.get_header("Content-type"), "application/json")
            self.assertEqual(json.loads(request.data), payload)

    def test_success_status_with_invalid_json_does_not_hide_api_failure(self):
        class Response:
            status = 200
            def __enter__(self):
                return self
            def __exit__(self, *args):
                pass
            def read(self):
                return b'<html>proxy error</html>'
        with patch.object(pinot, "urlopen", return_value=Response()):
            with self.assertRaisesRegex(pinot.InitializationError, "invalid JSON"):
                pinot.Controller("http://pinot").request("GET", "/schemas")

    def test_http_reads_retry_but_writes_are_not_blindly_retried(self):
        with patch.object(pinot, "urlopen", side_effect=URLError("offline")) as request:
            with patch.object(pinot.time, "sleep"):
                self.assertEqual(pinot.Controller("http://pinot").request("GET", "/schemas"), (503, None))
                self.assertEqual(request.call_count, 6)
                request.reset_mock()
                self.assertEqual(pinot.Controller("http://pinot").request("POST", "/schemas", {}), (503, None))
                self.assertEqual(request.call_count, 1)


class KafkaInitializationTests(unittest.TestCase):
    def run_creator(self, fail_topic=""):
        rendered = subprocess.check_output(["helm", "template", "pinpoint", str(ROOT),
                                            "--show-only", "templates/init-job-kafka.yaml"], text=True)
        script = rendered.split("              set -eu\n", 1)[1].split("          env:", 1)[0]
        script = "set -eu\n" + "\n".join(line[14:] for line in script.splitlines())
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory, "topics.json")
            state.write_text(json.dumps(["url-stat-unrelated-" + str(i) for i in range(8)]))
            mock = Path(directory, "kafka-topics")
            mock.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
p = Path(os.environ["TOPICS_STATE"])
topics = json.loads(p.read_text())
if "--list" in sys.argv:
    print("\\n".join(topics))
else:
    name = sys.argv[sys.argv.index("--topic") + 1]
    if name == os.environ.get("FAIL_TOPIC"):
        sys.exit(1)
    assert sys.argv[sys.argv.index("--replication-factor") + 1] == "3"
    if name not in topics:
        topics.append(name)
    p.write_text(json.dumps(topics))
''')
            mock.chmod(0o755)
            script = script.replace("/opt/bitnami/kafka/bin/kafka-topics.sh", str(mock))
            env = dict(os.environ, KAFKA_BOOTSTRAP_SERVERS="kafka.example:9092",
                       TOPIC_REPLICATION_FACTOR="3", TOPICS_STATE=str(state), FAIL_TOPIC=fail_topic)
            result = subprocess.run(["sh", "-c", script], env=env, capture_output=True, text=True)
            if not fail_topic:
                again = subprocess.run(["sh", "-c", script], env=env, capture_output=True, text=True)
                self.assertEqual(again.returncode, 0, again.stderr)
            return result, json.loads(state.read_text())

    def test_missing_topics_are_created_despite_unrelated_topics_and_reruns(self):
        result, topics = self.run_creator()
        self.assertEqual(result.returncode, 0, result.stderr)
        required = {"url-stat", "system-metric-data-type", "system-metric-tag", "system-metric-double",
                    "exception-trace", "inspector-stat-app", "inspector-stat-agent-00", "heatmap-stat-app-00"}
        self.assertTrue(required.issubset(topics))
        self.assertEqual(len(topics), 16)

    def test_failed_topic_creation_is_not_reported_as_success(self):
        result, topics = self.run_creator("system-metric-tag")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Topics created successfully", result.stdout)
        self.assertNotIn("inspector-stat-app", topics)


if __name__ == "__main__":
    unittest.main()
