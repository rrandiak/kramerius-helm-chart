# CDK configuration.properties part

This feature provides a Helm helper that generates the CDK section of `configuration.properties` from `.Values.cdk`.

The helper is used as a reusable part when building full `configuration.properties` for:
- `kramerius-public`
- `kramerius-curator`
- `workers`

It configures:
- `cdk.server.mode` — equals `cdk.enabled` when `cdk.server.mode` is omitted; set `cdk.server.mode` explicitly (including `false`) to override
- `cdk.forward.apache.client.max_connections` / `max_per_route` from `cdk.forwardClient.maxConnections` / `maxPerRoute` (omitted keys produce no line)
- `cdk.collections.sources.<name>.<key>` for each entry under `cdk.collections.sources` (typical keys: `baseurl`, `username`, `pswd`, `api`, `forwardurl`, `licenses`; see `configuration.properties.example`)
- optional `cdk.shibboleth.forward.headers` from `cdk.shibbolethForwardHeaders`

Cache JDBC properties (`cdk.cache.*`) come from the database helper, not this template.
