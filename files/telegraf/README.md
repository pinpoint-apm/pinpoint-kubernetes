# Bundled Telegraf configuration

`3.1.1/pinpoint-telegraf.conf` is an unmodified Apache License 2.0 file from
https://github.com/pinpoint-apm/pinpoint/blob/v3.1.1/metric-module/metric/src/main/telegraf/pinpoint-telegraf.conf

The ConfigMap replaces the Collector hostname with the release Service name.
This avoids a runtime GitHub download. Service port 15200 maps to Collector
3.1.1's MetricApp HTTP listener on 9995/TCP.
