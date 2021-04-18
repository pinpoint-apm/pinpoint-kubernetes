# Pinpoint

Pinpoint is an application monitoring platform.

## Add Repository for Dependency
Add helm repository for dependency (Stable,Incubator,Gradiant).
```
> helm repo add gradiant https://gradiant.github.io/charts
> helm repo add incubator https://charts.helm.sh/incubator 
> helm repo add stable https://charts.helm.sh/stable
```

## Deploy Pinpoint
```
> helm dependency update .
> kubectl create ns [Namespace]
> helm install [Release Name] . -n [Namespace]
```

## Uninstall Pinpoint
```
> helm uninstall [Release Name] -n [Namespace]
> kubectl delete ns [Namespace]
```

