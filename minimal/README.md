# Minimal: OpenSearch with the security plugin disabled

The smallest stack that runs Alfresco Search Community. No image builds, no persistent
volumes, no UI layer: just the repository, its database, the transform engine, and the two
services that make up the new search tier.

Use this variant to read the configuration. It is the shortest path from "what does
Alfresco Search Community need" to a working answer, and it is the base the other variants
build on.

## What it runs

| Service | Purpose |
| --- | --- |
| `postgres` | Repository database |
| `transform-core-aio` | Content transformations, including text extraction for indexing |
| `alfresco` | Content repository, with the `elasticsearch` search subsystem selected |
| `opensearch` | The search index, security plugin disabled |
| `batch-indexer` | Reads repository transactions and writes documents into the index |

## Start

```bash
docker compose up -d
```

First start takes a few minutes: the repository has to create its database schema, then the
`alfresco` index and its mappings in OpenSearch, before the indexer has anything to do.

## Access

- Alfresco REST API: http://localhost:8080/alfresco (`admin` / `admin`)
- OpenSearch: http://localhost:9200 (no authentication, security plugin disabled)

## Verify indexing

```bash
# The alfresco index should exist and its document count should climb
curl -s "http://localhost:9200/_cat/indices?v"

# Follow the indexer as it processes transactions
docker compose logs -f batch-indexer
```

Then search through the repository, which now answers via OpenSearch:

```bash
curl -s -u admin:admin -X POST \
  "http://localhost:8080/alfresco/api/-default-/public/search/versions/1/search" \
  -H 'Content-Type: application/json' \
  -d '{"query":{"language":"afts","query":"budget"}}'
```

## Stop

```bash
docker compose down
```

There are no volumes, so this discards everything. That is deliberate for this variant: see
`../solr-to-opensearch-migration` for a stack where persistence matters.

## Notes

- `solr.secureComms=secret` is mandatory on the repository. The value `none` is no longer
  supported in 26.2 for the X509 filter guarding the text extraction endpoint. Do not
  confuse it with OpenSearch's own security, which is switched off here through
  `DISABLE_SECURITY_PLUGIN=true`. The two settings are unrelated: one protects an Alfresco
  endpoint, the other protects OpenSearch.
- `solr.sharedSecret` on the repository and `ALFRESCO_CONTENT_TRANSFORM_SHAREDSECRET` on
  the indexer must hold the same value. Both come from `SHARED_SECRET` in `../.env`.
- The legacy `elasticsearch` and `solr` names persist throughout the product's
  configuration: the subsystem is called `elasticsearch`, the properties are
  `elasticsearch.*`, and the endpoint is `/alfresco/service/api/solr/textContent`. This is
  stable product terminology, not a misconfiguration.
- Because there are no volumes, every `docker compose down` starts from an empty repository
  and an empty index, which keeps the indexer's job trivial. The cursor seeding problem that
  `../solr-to-opensearch-migration` deals with simply does not arise here.
- For the same stack with TLS 1.3 enabled, see `../minimal-tls`.
