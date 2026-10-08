# PostgreSQL and Pinpoint 3.1.1

An external PostgreSQL server **cannot replace MySQL with the stock 3.1.1
application images just by changing the JDBC URL**. The chart can inject a
custom JDBC URL/driver/Secret, but that is configuration support for custom
application images, not PostgreSQL runtime compatibility.

The released Web JAR contains `mapper/AgentStaticsMapper.xml`, whose
`insertAgentCount` statement uses MySQL `ON DUPLICATE KEY UPDATE`. The datasource
module supplies `datasource/mysql-driver.properties`. The bundled MySQL schemas
also use `AUTO_INCREMENT`, unsigned integers, backtick quoting and MySQL index
syntax. Changing only the driver does not port these statements or schemas.

To support PostgreSQL, maintain and test an application adaptation:

1. Include PostgreSQL JDBC in the relevant Web/Collector/Batch distributions,
   and select the correct datasource properties for **both** primary and
   metadata connections.
2. Port the application schema, constraints, identity columns and indexes;
   use the Spring Batch PostgreSQL schema if running Batch.
3. Audit all enabled modules' relational DAO/MyBatis statements and replace
   MySQL-specific operations, including the agent-statistics upsert, with
   PostgreSQL equivalents. Keep both database dialects if contributing upstream.
4. Build versioned custom images and test empty schema initialization,
   repeat initialization, login/user/team/alarm/webhook functionality, agent
   statistics, metadata reads/writes, connection pooling and backup/restore.
   Exercise Batch repository behavior if Classic/Batch is enabled.

Configure `mysql.enabled=false`, a PostgreSQL JDBC URL, `org.postgresql.Driver`,
application credentials via `global.datasource.passwordSecret` and the adapted
images only after those tests pass. The chart does not automatically create
PostgreSQL tables. HBase remains the trace store and Pinot remains the Metric
store; PostgreSQL would replace the relational MySQL component only.

This is a separate upstream application compatibility change. The current
3.1.1 chart release does not advertise stock PostgreSQL support.
