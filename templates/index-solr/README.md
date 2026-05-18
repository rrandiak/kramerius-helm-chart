# Index Solr configuration.properties part

This feature generates the Solr section of `configuration.properties` from
`.Values.solrConfig`.

It is configuration-only (no standalone Kubernetes workload resources in this
folder) and is consumed when building full `configuration.properties` for:
- `kramerius-public`
- `kramerius-curator`
- `workers`

## What it configures

`solrConfig` keys map to these properties:
- `search` -> `solrSearchHost`
- `searchUseComposite` -> `solrSearch.useCompositeId`
- `processing` -> `solrProcessingHost`
- `sdnnt` -> `solrSdnntHost`
- `logs` -> `k7.log.solr.point`
- `monitor` -> `api.monitor.point`
- `monitorThreshold` -> `api.monitor.threshold`
- `updates` -> `solrUpdatesHost` (CDK mode)
- `reharvest` -> `solrReharvestHost` (CDK mode)
- `clientConfig.maxConnections` -> `solr.apache.client.max_connections`
- `clientConfig.maxPerRoute` -> `solr.apache.client.max_per_route`
- `clientConfig.connectTimeout` -> `solr.apache.client.connect_timeout`
- `clientConfig.responseTimeout` -> `solr.apache.client.response_timeout`

## CDK behavior

When `cdk.enabled=true`, both `solrConfig.updates` and
`solrConfig.reharvest` are required. Rendering fails with a clear error if one
is missing.

## Usage

The root configuration builder includes this feature via:
- `kramerius.solrConfigurationPropertyMap` (map generation)
- `kramerius.configurationProperties.solrSection` (final section rendering)
