## Custom Configuration for Pinpoint Agent
If you don't want to use the default configuration in Pinpoint Agent release, put your custom configuration files in this directory.
And then you create ConfigMap by setting **agent.externalConfigName** in `values.yaml`. 
Lastly, You can mount this ConfigMap and use that.


### Caution! 
- **agent.exxternalConfigName** has to be same with file name which is located in `files/conf/`.
- ConfigMap's name is `external-config-{{ .Values.agent.externalConfigName }}`.
