# Pinpoint Helm Chart

![Version: 1.0.0](https://img.shields.io/badge/Version-1.0.0-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 2.5.4](https://img.shields.io/badge/AppVersion-2.5.4-informational?style=flat-square)

A Helm chart for deploying [Pinpoint APM](https://github.com/pinpoint-apm/pinpoint) on Kubernetes.

---

## ✨ Features

- Deploys Pinpoint Collector, Web, Agent, HBase, MySQL, Redis, and Zookeeper
- Optional: Deploys Pinpoint Batch (for alarms) and Flink (for inspection) modules.
- Quickstart test application for easy validation
- Configurable resources, persistence, and service types
- Flexible customization via `values.yaml` or CLI

---

## 🛠 Prerequisites

- Kubernetes **1.21+**
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

- Global Settings:
    - `global.pinpointVersion`: Sets the version for all Pinpoint components.
- Component Toggles:
    - `web.enabled`, `collector.enabled`, `hbase.enabled`: Enable or disable core components.
    - `mysql.enabled`, `zookeeper.enabled`, `redis.enabled`: Enable or disable dependencies.
    - `batch.enabled`, `flink.enabled`: Enable optional modules for alarms and inspection.
    - `quickstart.enabled`: Deploy a test application to verify the installation.
- Scaling & Performance:
    - `web.replicaCount`, `collector.replicaCount`: Set the number of replicas for Web and Collector pods.
    - `web.resources`,`collector.resources`: Configure CPU and memory requests/limits.
- Security & Passwords:
    - `mysql.auth.rootPassword`, `mysql.auth.password`: Set passwords for the MySQL database.
    - `web.config.adminPassword`: Set the admin password for the Pinpoint Web UI.
    - `web.config.security.enable`: Enable or disable the login screen for the Web UI.
- Persistence & Storage:
    - `hbase.persistence.size`: Set the PVC size for HBase data storage.
    - `mysql.primary.persistence.size`: Set the PVC size for the MySQL database.
    - `zookeeper.persistence.size`: Set the PVC size for Zookeeper data.
Network & Access:
    - `web.ingress.enabled`: Enable to create a Kubernetes Ingress for the Web UI.
    - `web.ingress.hosts`: Configure the hostname(s) to access the UI.

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
