# Sharing an OpenSearch cluster with hxpr and Content Lake App

How to let the OpenSearch instance used by Alfresco Search Community (index `alfresco`) live
in the same cluster as hxpr, the platform behind
[Content Lake App](https://github.com/aborroy/content-lake-app), which uses OpenSearch for
semantic and RAG search (index `nuxeo_embeddings*`).

**This is infrastructure coexistence, not data interoperability.** One OpenSearch cluster, two
independent indexes. Content Lake App neither reads nor writes the `alfresco` index. hxpr
creates and manages its own `nuxeo_embeddings*` index with a RAG-oriented document schema based
on kNN vectors, completely unlike the repository schema (`PATH`, `ASPECT`, `OWNER`) the batch
indexer produces.

## Requirement 1: OpenSearch version

hxpr, through `content-lake-app-deployment/compose.hxpr.yaml`, defaults to:

```
OPENSEARCH_TAG=3.5.0
```

Verified empirically: Alfresco Community 26.2 and `alfresco-elasticsearch-batch-indexing` work
against `opensearchproject/opensearch:3.5.0` with no additional changes. That image reports
`minimum_wire_compatibility_version: 2.19.0`. Using the same image tag in the Alfresco compose
file instead of the 2.x default is sufficient.

The check was run with the [`minimal`](../minimal/) deployment and `OPENSEARCH_TAG=3.5.0`: the
repository created the `alfresco` index and its mappings, the indexer populated it to the same
document count as on 2.19.6, full-text search through the repository returned the expected
result, and the indexer logged no errors.

## Requirement 2: the security plugin

hxpr deploys OpenSearch with the security plugin disabled **at plugin level**, not merely
without TLS, using the native OpenSearch property rather than the entrypoint's convenience
variable:

```yaml
environment:
  plugins.security.disabled: "true"
  # Still required by the demo config installer that runs at startup, even though security
  # is disabled afterwards via plugins.security.disabled
  OPENSEARCH_INITIAL_ADMIN_PASSWORD: ${OPENSEARCH_ADMIN_PASSWORD:-Hyland_Pass1!}
```

The deployments in this repository use `DISABLE_SECURITY_PLUGIN: "true"`, a variable read by
`opensearch-docker-entrypoint.sh` and translated internally to
`plugins.security.disabled=true`. The effect is identical, so either variable works when
bringing Alfresco up alongside hxpr.

Do not mix a security-enabled Alfresco search tier (see [`minimal-tls`](../minimal-tls/)) with
hxpr without also adapting hxpr's credentials: its `hxpr-app` service's `OPENSEARCH_ADDRESSLIST`
carries no username or password in the default example.

## Requirement 3: derived_source workaround on OpenSearch 3.5, only if kNN is enabled

To reproduce the hxpr environment faithfully, register a template that disables
`knn.derived_source` **before hxpr creates its index**. This works around a known OpenSearch 3.5
bug where hybrid kNN plus text searches fail in the fetch phase after a segment merge:

```bash
curl -X PUT "http://localhost:9200/_index_template/nuxeo-embeddings-noderivedsource" \
  -H 'Content-Type: application/json' \
  --data-binary '{
    "index_patterns": ["nuxeo_embeddings", "nuxeo_embeddings_*"],
    "priority": 500,
    "template": {
      "settings": {
        "index": {
          "knn": true,
          "knn.derived_source.enabled": false
        }
      }
    }
  }'
```

This is not needed for the `alfresco` index, which does not use kNN, and it does not affect it:
the name does not match the `nuxeo_embeddings*` pattern.

## Trying it out

1. Override the OpenSearch tag for any deployment in this repository:

   ```bash
   OPENSEARCH_TAG=3.5.0 docker compose up -d
   ```

   Or change `OPENSEARCH_TAG` in [`../.env`](../.env) to apply it everywhere.

2. Confirm the `alfresco` index is created and populated exactly as it is on 2.x:

   ```bash
   curl -s "http://localhost:9200/_cat/indices?v"
   docker compose logs -f batch-indexer
   ```

3. Optionally, to demonstrate coexistence, register the template above and bring up
   `hxpr-app`, then check that both `alfresco` and `nuxeo_embeddings` appear in
   `_cat/indices` without conflict.

## Sources

- https://github.com/aborroy/content-lake-app-deployment (`compose.hxpr.yaml`,
  `hxpr/opensearch/init.sh`, `hxpr/opensearch/index-template.json`)
- https://github.com/aborroy/content-lake-app
