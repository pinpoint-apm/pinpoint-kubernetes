# Chart 4.0.1

Targets Pinpoint 4.0.1; companion storage chart 0.2.0 adds versioned bootstrap
assets. MySQL requires 8.4+. New assets include the service-alarm schema and
the Pinot exceptionTrace serviceName field. Schema upgrades are additive and
explicit for existing Pinot installations. See [UPGRADING](UPGRADING.md).

The chart retains 3.1.1 assets for compatibility testing. Default services use
v4 identities; sample agents report to DEFAULT. OTLP/HTTP adds port 9997.
Service Alarm is opt-in and requires a separately supplied compatible image;
no unpublished upstream image is silently referenced.

Local qualification passed: fresh k3s installation, native/OTLP traffic,
two-replica login, SQL recovery, retention, worker maintenance with PDB protection
and application upgrade with retained data. Production placement requires two
eligible workers; shutdown allows endpoint propagation before termination.
See [validation results](VALIDATION-4.0.1.md). This candidate is unpublished;
DEV upgrades and release publication are separate steps.
