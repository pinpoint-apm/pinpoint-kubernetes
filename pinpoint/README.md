# Pinpoint

Pinpoint is an application monitoring platform.

## Add Repository for Dependency
Add helm repository for dependency (Stable,Incubator,Gradiant).
```
> helm repo add gradiant https://gradiant.github.io/charts
> helm repo add incubator https://charts.helm.sh/incubator 
> helm repo add stable https://charts.helm.sh/stable
```

---
## Deploy Pinpoint
```
> helm dependency update pinpoint
> helm install [Release Name] pinpoint -n [Namespace]
```

---
## Use Pinpoint Agent

### Java Agent
#### Release Download
To use java agent, you need to download the release files with the version you want to use. When you set the **agent.version** in `pinpoint-agent/values.yaml`, the process to download the release files run before installing or upgrading the chart.


There are two components to download release files.

- **release-pvc** : `relese-pvc` is the PVC to create volume which is stored the release files. If you set the storageClass for this PVC, the PVC and PV is provisioning by using the storageClass you set. Otherwise, the default storageClass is used. 

- **release-download-job** : 'release-download-job' is the Job to download the release files you want to use.
#### Custom Configuration
If you don't want to use the default configuration in Pinpoint Agent release, put your custom configuration files in `files/conf/`.
And then you create ConfigMap by setting **agent.externalConfigName** in `values.yaml`. Lastly, You can mount this ConfigMap and use that.

#### Caution!
- **agent.externalConfigName** has to be same with file name which is located in `files/conf/`.
- ConfigMap's name is fixed to `external-config-{{ .Values.agent.externalConfigName }}`.
- PVC's name is fixed to `agent-<version>-pvc`.
- When you mount the PVC in your application, you have to set `readOnly: true` in PVC to prevent the unintentional changes.
- The deletion for unsed PVC is not supported.


#### Example Deployment
There is a example Deployment manifest using release files and custom configuration.
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-deploy-1
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test-deploy
  template:
    metadata:
      labels:
        app: test-deploy
    spec:
      containers:
      - name: test
        image: alpine
        command:
        - sh
        - -c
        - |
          tail -f /dev/null
        env:
          - name: EXTERNAL_CONFIG_PATH
            value: "/pinpoint/config/<custom-configuration-name>"
        volumeMounts:
        - name: agent-init
          mountPath: /agent-init
        - name: agent-external-config
          mountPath: /pinpoint/config
      volumes:
      - name: agent-init
        persistentVolumeClaim:
            claimName: agent-<agent-version>-pvc
            readOnly: true
      - name: agent-external-config
        configMap:
          name: external-config-<custom-configuration-name>
```