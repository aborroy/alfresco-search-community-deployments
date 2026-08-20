# Migrating from Solr 6 to Alfresco Search Community

A single `compose.yaml` running both search engines at once: the existing Solr 6 and the new
OpenSearch with its batch indexer, plus the cursor seeding needed to index existing history.

Use this variant to rehearse a real migration. It is the only variant here where persistence,
ordering, and rollback all matter.

Both phases are driven by environment variables, so the file itself never needs editing:

| Variable | Phase 1 (side by side) | Phase 2 (OpenSearch only) |
| --- | --- | --- |
| `MAX_GAP_AGE` | `0` (no limit, processes history) | `24h` (steady state) |
| `SOLR_TRACKING` | `true` (Solr stays current) | `false` |
| `MAX_WINDOW` | `30m` default; raise it only for years of history | `30m` |
| `SEED_EPOCH_MS` | optional; computed from the database by default | not applicable |

## Before phase 1: the namespace prefix map

A repository that has been running on Solr 6 for years usually has custom content models
deployed. Solr resolved namespace prefixes through the repository. The batch indexer reads the
database directly and resolves them through a static JSON file instead, and any namespace missing
from that file is indexed silently and incompletely: a node whose own type comes from your model
is not indexed at all. Full explanation in
[../docs/custom-content-models.md](../docs/custom-content-models.md).

Do this before the first `docker compose up`. History is walked once, in ascending commit time,
so nodes the catch-up already passed are not revisited when you correct the file later. Getting it
wrong means reseeding the cursor and processing the whole history again.

With no custom model in the repository, nothing here is needed and the stack runs as it is.

1. Download the addon JAR and mount it into the `alfresco` service, appending to the `volumes`
   list it already has for `alf-data`, as described in
   [../docs/custom-content-models.md](../docs/custom-content-models.md).

2. Start the repository on its own, so the dictionary is available while the indexer is still
   held back, and fetch the map once it reports ready:

   ```bash
   docker compose up -d alfresco
   docker compose ps alfresco          # wait for healthy
   mkdir -p config
   ../tools/fetch-prefix-map.sh > config/prefixes.json
   ```

3. Point the indexer at the file, in `compose.yaml`:

   ```yaml
     batch-indexer:
       environment:
         JAVA_OPTS: -Dalfresco.reindex.prefixes-file=file:/config/prefixes.json
       volumes:
         - ./config/prefixes.json:/config/prefixes.json:ro
   ```

Then start phase 1 as below. The cursor seeding and the indexer come up in order, with the map
already in place.

## Phase 1: Solr and OpenSearch side by side

The repository already searches through OpenSearch, but Solr keeps indexing as changes
arrive, so it remains a valid rollback target at any moment.

```bash
docker compose up -d
```

Startup order, resolved by `depends_on`: postgres and transform, then OpenSearch, then
Alfresco (which creates the `alfresco` index and its mappings), then the cursor seeding, then
the batch indexer.

The cursor is seeded automatically at `MIN(commit_time_ms)` of `alf_transaction`, the
repository's first real transaction. No date needs to be supplied. To force one:

```bash
SEED_EPOCH_MS=1577836800000 docker compose up -d
```

Follow the history catch-up. The cursor advances one window (`MAX_WINDOW`) per cycle:

```bash
docker compose logs -f batch-indexer | grep "reindexByDate cycle"
```

While `[chunked gap recovery - more chunks pending]` keeps appearing, history is still being
recovered. On a demo repository (around 870 nodes, minutes of history) a full catch-up takes
roughly a minute. Inspect the cursor directly:

```bash
curl -s http://localhost:9200/alfresco-reindex-state/_doc/reindexByDate-watermark \
  | python3 -m json.tool
```

Confirm both engines are current before going further:

```bash
# OpenSearch: document count
curl -s "http://localhost:9200/alfresco/_count"

# Solr: indexed nodes and transaction lag, where TX Lag must be 0 s
curl -s -H "X-Alfresco-Search-Secret: demosecret" \
  "http://localhost:8083/solr/admin/cores?action=SUMMARY&wt=json"

# Search through the repository, which already answers via OpenSearch.
# Replace the term with something you know exists in your repository: on a repository
# with no content of its own this correctly returns zero hits.
curl -s -u admin:admin -X POST \
  "http://localhost:8080/alfresco/api/-default-/public/search/versions/1/search" \
  -H 'Content-Type: application/json' -d '{"query":{"language":"afts","query":"budget"}}'
```

Do not move to phase 2 until the cursor has reached the present, search results look correct,
and the dead-letter index (`alfresco-reindex-dead-letter`) is not accumulating failures.

If the repository has custom content models, check the other silent failure too. `filterCount`
has to be `0` and there must be no `impossible to` lines, which is what an incomplete prefix map
produces:

```bash
docker compose logs batch-indexer | grep -e "impossible to" -e "Job metrics"
```

## Phase 2: stop Solr and put OpenSearch into steady state

```bash
docker compose stop solr6

MAX_GAP_AGE=24h SOLR_TRACKING=false \
  docker compose up -d --no-deps alfresco batch-indexer
```

This returns the scheduling properties to their steady-state values and stops feeding Solr's
tracking. Restarting Alfresco is required because `search.solrTrackingSupport.enabled` is read
at startup. To release Solr's resources entirely:

```bash
docker compose rm -sf solr6
```

## Rollback during phase 1

While Solr is still current, going back means switching the subsystem and restarting the
repository. In this demo the subsystem is pinned in `JAVA_OPTS`, so `compose.yaml` has to be
edited (`-Dindex.subsystem.name=elasticsearch` to `solr6`) and the container recreated:

```bash
docker compose up -d --no-deps --force-recreate alfresco
```

The OpenSearch index needs no cleanup: leave it as it is and retry the migration later. In a
real installation the property lives in `alfresco-global.properties` or is changed from the
admin console, with nothing to rebuild.

## Access

- Alfresco REST API: http://localhost:8080/alfresco (`admin` / `admin`)
- OpenSearch: http://localhost:9200 (security plugin disabled)
- Solr 6: http://localhost:8083/solr (requires the header `X-Alfresco-Search-Secret: demosecret`)
- Batch indexer actuator: http://localhost:8091/actuator/health

## Notes

- **The cursor has to be seeded.** On a first start with no cursor, the batch indexer begins
  at "now" and never indexes pre-existing content. The `cursor-seed` service writes the
  watermark document before the indexer's first start. It uses `_create`, so an existing
  cursor is never overwritten and a migration already in progress does not restart.
- **Seed the cursor from the database, not from a fixed date.** Catch-up processes one window
  (`MAX_WINDOW`) per cycle and walks the calendar, not the documents. Seeding "2020" on a
  repository created yesterday forces the indexer through years of empty windows at 30m per
  cycle. With the cursor at the first real transaction, catch-up time is proportional to the
  history that actually exists. To migrate years of history, raise `MAX_WINDOW`, to `7d` for
  example.
- **`search.solrTrackingSupport.enabled` must be forced to `true` during phase 1.** The
  `elasticsearch` subsystem defaults it to `false` in
  `subsystems/Search/elasticsearch/elasticsearch.properties`. Without the override, Solr stops
  receiving data the moment the repository switches subsystem, and goes stale exactly when you
  want it as a rollback target.
- **`solr.secureComms=secret` is mandatory** on the repository, with OpenSearch too: it
  protects the text extraction endpoint (`/alfresco/service/api/solr/textContent`) that the
  batch indexer calls. Its value must match `ALFRESCO_CONTENT_TRANSFORM_SHAREDSECRET`.
- **The volumes are required, not a nicety.** Phase 2 recreates the Alfresco container, and
  without a volume for `alf_data` the content disappears while the database still points at
  it, leaving a repository that will not even start (`CONTENT INTEGRITY ERROR`). To start
  clean: `docker compose down -v`.
- This stack is a demo: no TLS, and OpenSearch security disabled. For the TLS 1.3 example see
  `../minimal-tls`.
