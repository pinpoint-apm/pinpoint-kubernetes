# Pinpoint

Pinpoint is an application monitoring platform.

## Add Repository for Dependency
Add helm repository for dependency (Stable,Incubator,Gradiant).
```
> helm repo add gradiant https://gradiant.github.io/charts
> helm repo add incubator https://kubernetes-charts-incubator.storage.googleapis.com
> helm repo add stable https://kubernetes-charts.storage.googleapis.com
```

## Deploy Pinpoint
```
> helm dependency update pinpoint
> helm install [Release Name] pinpoint -n [Namespace]
```