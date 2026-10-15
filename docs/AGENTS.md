# Instrumenting applications

Pinpoint agents run inside your application's JVM. The `pinpointdocker/pinpoint-agent`
image only carries the agent files, so add it to application pods as an init
container that copies the agent into a shared volume. The chart's demo
Quickstart uses the same pattern.

The standalone `agent` Deployment shipped before chart 3.1.5 could not instrument
other pods and used wrong stat/span ports; it was removed. Setting
`agent.enabled=true` now fails with a pointer to this page.

## Collector ports

| Purpose | Collector Service port | Agent property |
| --- | --- | --- |
| Agent and metadata | 9991/TCP | `profiler.transport.grpc.agent.collector.port`, `profiler.transport.grpc.metadata.collector.port` |
| Statistics | 9992/TCP | `profiler.transport.grpc.stat.collector.port` |
| Spans | 9993/TCP | `profiler.transport.grpc.span.collector.port` |

The defaults of the 3.1.1 agent already use these ports. Set only the
Collector host unless you changed `collector.service.ports`.

## Kubernetes example

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: orders
spec:
  selector:
    matchLabels: {app: orders}
  template:
    metadata:
      labels: {app: orders}
    spec:
      initContainers:
        - name: pinpoint-agent
          image: pinpointdocker/pinpoint-agent:3.1.1
          command: ["sh", "-c", "cp -r /pinpoint-agent/. /agent"]
          volumeMounts:
            - {name: pinpoint-agent, mountPath: /agent}
      containers:
        - name: orders
          image: registry.example.com/orders:1.4.2
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef: {fieldPath: metadata.name}
            - name: JAVA_TOOL_OPTIONS
              value: >-
                -javaagent:/agent/pinpoint-bootstrap.jar
                -Dpinpoint.applicationName=orders
                -Dpinpoint.agentId=$(POD_NAME)
                -Dpinpoint.profiler.profiles.active=release
                -Dprofiler.transport.grpc.collector.ip=pinpoint-collector.pinpoint.svc
          volumeMounts:
            - {name: pinpoint-agent, mountPath: /agent}
      volumes:
        - name: pinpoint-agent
          emptyDir: {}
```

- `agentId` must be unique per JVM and, like `applicationName`, at most 24
  characters with the 3.1.1 agent defaults. Pod names fit for short Deployment
  names (`orders-7d9f8b6c5d-x2k4p`); use a shorter unique value for long names.
  `applicationName` groups replicas of the same service.
- Copy the agent with the same user as the application, or make the copied files
  writable for it: the agent writes logs below its own directory.
- The stock agent image is amd64-only; select amd64 nodes or build your own image.
- Sampling and other agent properties can be appended as `-D` options; see the
  [agent configuration](https://github.com/pinpoint-apm/pinpoint/blob/v3.1.1/agent-module/agent/src/main/resources/pinpoint-root.config).

## Network access

In-cluster agents in another namespace need DNS and TCP access to the Collector
Service. With `networkPolicy.enabled=true`, label the agent namespaces:

```bash
kubectl label namespace orders pinpoint-apm.io/agent-access=true
```

Agents outside the cluster need a reachable endpoint for the three gRPC ports.
Enable `collector.externalService` (NodePort or LoadBalancer) as described in
the [README](../README.md#connect-agents); the Web ingress cannot carry agent
traffic.
