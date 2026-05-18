# Lock Server configuration.properties part

This feature provides helpers that generate the Lock Server section of
`configuration.properties` from `.Values.hazelcast`.

The generated part is included when building full `configuration.properties`
for:
- `kramerius-public`
- `kramerius-curator`
- `workers`

## What it configures

`hazelcast` keys map to:
- `hazelcast.server.addresses` -> generated from namespace as `hazelcast.<namespace>.svc.cluster.local:5701`
- `hazelcast.instance` -> from `hazelcast.instance` (default `akubrasync`)
- `hazelcast.user` -> from `hazelcast.user` (default `dev`)

## Usage

Lock-server feature helpers:
- `kramerius.lockServerConfigurationPropertyMap`
- `kramerius.configurationProperties.lockServerSection`

The runtime workload remains the same (`StatefulSet`, headless `Service`,
`ServiceAccount` under `templates/lock-server/`), and now supports optional
`hazelcast.image.pullSecret` in pod `imagePullSecrets`.
