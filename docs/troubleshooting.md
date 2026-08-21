# Troubleshooting

Symptoms seen while building and running these deployments, and what causes them.

## The index is empty and stays empty

```bash
curl -s "http://localhost:9200/_cat/indices?v"
```

**No `alfresco` index at all.** The repository creates the index and its mappings at startup,
not the indexer. Check that the repository came up healthy and that
`elasticsearch.createIndexIfNotExists=true` is set. If the repository could not reach
OpenSearch, its log shows connection failures on port 9200.

**Index exists, `docs.count` is 0, and the repository already had content.** The cursor started
at "now", so pre-existing content is outside the indexer's window. This is expected on any
first start without cursor seeding. See
[architecture.md](architecture.md#the-indexing-cursor), and the `cursor-seed` service in
`solr-to-opensearch-migration/compose.yaml` for the fix.

**Index exists, count is 0, and content was added after startup.** Follow the indexer:

```bash
docker compose logs -f batch-indexer
```

## Searching the trashcan returns HTTP 500

A search scoped to deleted nodes fails outright:

```bash
curl -s -u admin:admin -X POST \
  "http://localhost:8080/alfresco/api/-default-/public/search/versions/1/search" \
  -H 'Content-Type: application/json' \
  -d '{"query":{"query":"*"},"scope":{"locations":["deleted-nodes"]}}'
```

```
"briefSummary":"Request failed: [index_not_found_exception] no such index [alfresco-archive]"
```

Not a misconfiguration, and there is nothing to fix in the deployment. The repository routes
archive-store queries to `elasticsearch.archive.indexName`, and no component of the product creates
or fills that index: `elasticsearch.createIndexIfNotExists` covers only the main index, the
repository has no write path to OpenSearch, and the batch indexer has no notion of the archive
store.

**The remedy is to stop issuing the query.** Searching deleted nodes is not available on this
subsystem. Do not create `alfresco-archive` by hand to make the error go away: the request would
then return HTTP 200 with zero results, which is indistinguishable from a genuine absence of
matches and hides the missing feature instead of reporting it. See
[architecture.md](architecture.md#the-archive-index-does-not-work-do-not-use-it).

## Metadata is indexed but content text is not

Searches match on filenames and properties but never on words inside documents. The shared
secret does not match: `solr.sharedSecret` on the repository against
`ALFRESCO_CONTENT_TRANSFORM_SHAREDSECRET` on the indexer. Metadata indexing does not go through
the guarded endpoint, so it keeps working and hides the cause.

Both values come from `SHARED_SECRET` in `.env`, so a mismatch means one service did not pick
the file up. Confirm what each container actually received:

```bash
docker compose exec batch-indexer env | grep SHAREDSECRET
```

## Search returns more results than the query should allow

Not a bug in the deployment. The `elasticsearch` subsystem silently drops query conditions it
does not support, so a condition intended to narrow results disappears and the remaining query
matches more broadly. Look for `Ignoring query condition because:` at WARN level in the
repository log. See [architecture.md](architecture.md#known-limitation).

## Repository will not start: CONTENT INTEGRITY ERROR

The database has metadata for content that is no longer on disk, because the Alfresco container
was recreated without a volume for `alf_data`. There is no repair from this state in a demo.
Start clean:

```bash
docker compose down -v
```

## PostgreSQL exits with "data directory has wrong ownership"

The database directory is bind-mounted from the host. On Docker Desktop the host files carry
the host user's uid, PostgreSQL runs as its own user inside the image, and it refuses to start
on a directory it does not own. Use a named volume for the data directory instead, as all four
deployments here now do. Bind mounts stay fine for logs and read-only configuration.

## Catch-up never seems to finish

The indexer logs `[chunked gap recovery - more chunks pending]` cycle after cycle. Catch-up
covers one `maxWindow` of calendar time per cycle regardless of how many documents fall inside
it, so a cursor seeded far in the past crawls through empty windows.

Check where the cursor actually is:

```bash
curl -s http://localhost:9200/alfresco-reindex-state/_doc/reindexByDate-watermark \
  | python3 -m json.tool
```

If `lastSuccessfulToTimeEpochMs` is advancing but far behind, raise the window rather than
waiting:

```bash
MAX_WINDOW=7d docker compose up -d --no-deps batch-indexer
```

## Nodes using a custom content model are missing or incomplete

Only with a content model of your own deployed. Two shapes, both silent:

- Nodes whose **type** comes from your model are absent from the index entirely, and the
  dead-letter index is empty.
- Nodes that merely **carry** one of your aspects are present, but without the aspect's
  properties and without the aspect in their `ASPECT` field.

The indexer cannot map your namespace URI to its prefix. Look for this in its log:

```bash
docker compose logs batch-indexer | grep "impossible to"
```

The fix is a complete prefix map, generated from the repository itself with
`tools/fetch-prefix-map.sh`. See [custom-content-models.md](custom-content-models.md).

## The indexer fails on validateDbSchemaStep with "Cannot parse null string"

The prefix map it loaded is missing Alfresco's own namespaces, so it cannot read the repository
descriptor. This happens when `alfresco.reindex.prefixes-file` points at a hand-written file
holding only custom namespaces: the file replaces the shipped map rather than extending it.
Fetch a complete map with `tools/fetch-prefix-map.sh`, which refuses to write one that is missing
Alfresco's own namespaces.

## Documents are failing rather than indexing

Failures accumulate in a dead-letter index:

```bash
curl -s "http://localhost:9200/alfresco-reindex-dead-letter/_search?size=5" \
  | python3 -m json.tool
```

A non-empty dead-letter index during a migration means do not proceed to phase 2 yet.

## OpenSearch exits immediately on start

**`minimal-tls` only.** Two common causes.

Private key permissions: OpenSearch refuses to start if the key is group or world readable.
`generate-certs.sh` sets mode 600, so this points at certificates created some other way.

Missing certificates: the compose file bind-mounts individual files from `certs/`. If they do
not exist, Docker creates directories in their place and OpenSearch fails to parse them. Remove
the stray directories and generate properly:

```bash
rm -rf certs && ./generate-certs.sh
```

Check the container log for the real error:

```bash
docker compose logs opensearch
```

## TLS 1.2 connection succeeds when it should fail

**`minimal-tls` only.** The TLS 1.3 restriction did not apply, which means the settings file
was not appended to `opensearch.yml`. Confirm what the container ended up with:

```bash
docker compose exec opensearch grep -A2 enabled_protocols /usr/share/opensearch/config/opensearch.yml
```

Note that `curl --tlsv1.2` alone only sets a *minimum* version and will happily negotiate
1.3. The test needs `--tls-max 1.2` as well.

## Ports already in use

The deployments share ports (8080, 9200) and are meant to be run one at a time. Stop the other
one first:

```bash
docker compose ls
docker compose -f ../minimal/compose.yaml down
```

## full-stack build fails fetching the ActiveMQ broker

The repository Dockerfile downloads the JAR from Maven Central and verifies its checksum. A
failure here is either no network access from the build, or a proxy interfering with the
download. The build argument can point elsewhere if you mirror Maven Central internally.
