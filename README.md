# Pinpoint Helm Chart

![Version: 1.0.0](https://img.shields.io/badge/Version-1.0.0-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 2.5.4](https://img.shields.io/badge/AppVersion-2.5.4-informational?style=flat-square)

A Helm chart for deploying [Pinpoint APM](https://github.com/pinpoint-apm/pinpoint) on Kubernetes.

<img width="1918" height="942" alt="image" src="https://github.com/user-attachments/assets/da04fa9d-da28-4212-843d-27ea4fcda531" />

---

## ℹ️ Default Versions

- **Pinpoint Version (default):** 2.5.4
- **Kubernetes:** 1.23+ (tested up to v1.33.1)
- **Helm:** 3.2.0+ (tested up to v3.18.6)

---

## ✨ Features

- Deploys Pinpoint Collector, Web, Agent, HBase, MySQL, Redis, and Zookeeper
- Optional: Deploys Pinpoint Batch (for alarms) and Flink (for inspection) modules.
- Quickstart test application for easy validation
- Configurable resources, persistence, and service types
- Flexible customization via `values.yaml` or CLI
- Production-ready defaults and health checks

---

## 🛠 Prerequisites

- Kubernetes **1.23+**
- Helm **3.2.0+**
- Persistent storage provisioner (for MySQL, HBase, Zookeeper)

---
## 🚀 Quick Start

1. **Clone the repository:**
    ```sh
    git clone https://github.com/pinpoint-apm/pinpoint-kubernetes.git
    cd pinpoint-helm
    ```

2. **Update chart dependencies:**
    ```sh
    helm dependency update
    ```

3. **Install the chart:**
    ```sh
    helm install pinpoint . -n pinpoint --create-namespace
    ```

4. **Monitor pods:**
    ```sh
    kubectl get pods -n pinpoint -w
    ```

---

## 🛠️ Configuration

The most important parameters in `values.yaml`:

- `web.enabled`, `collector.enabled`, `hbase.enabled`, `mysql.enabled`, `redis.enabled`, `zookeeper.enabled`: Enable/disable main components
- `batch.enabled`, `flink.enabled`: Enable/disable optional modules (Alarm and Inspector)
- `web.replicaCount`, `collector.replicaCount`: Number of replicas
- `mysql.auth.rootPassword`, `mysql.auth.password`: MySQL passwords
- `web.config.adminPassword`: Web admin password
- `hbase.persistence.size`: HBase PVC size
- `quickstart.enabled`: Enable test application

See `values.yaml` for all options.

---

## 🛠️ Customize Values

You can customize the deployment by editing `values.yaml` or using `--set` on the command line. Example:

```sh
helm install pinpoint . -n pinpoint \
  --set mysql.auth.rootPassword=MyRootPass \
  --set web.replicaCount=2 \
  --set collector.resources.limits.cpu=500m
```

Or create your own values file:

```sh
cp values.yaml my-values.yaml
# Edit my-values.yaml as needed
helm install pinpoint . -n pinpoint -f my-values.yaml
```

---

## 🧹 Uninstallation

Remove the pinpoint release:

```sh
helm uninstall pinpoint -n pinpoint
```

---

## 📄 License

This project is licensed under the Apache 2.0 License.

---

## 📚 References

- [Pinpoint Documentation](https://github.com/pinpoint-apm/pinpoint)
- [Helm Documentation](https://helm.sh/docs/)
