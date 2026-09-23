# Inspecting Alfresco Search Community from OpenSearch Dashboards

A copy-pasteable query set that answers two questions against a running Alfresco Search Community
deployment:

1. Which indexes exist, who creates them, and what each one is for.
2. What fields make up an indexed document, and how to see the ones that do not appear in `_source`.

Every query below was executed against a live stack, not transcribed from documentation. Versions:
ACS Community 26.2.0, `alfresco-elasticsearch-batch-indexing:5.7.1`, OpenSearch and OpenSearch
Dashboards 2.19.6, PostgreSQL 17.9. Outputs quoted in the notes come from that run.

## Three ways to run these

**Dev Tools console (recommended).** Open `http://localhost:5601/app/dev_tools#/console` and paste the
`GET`/`POST` blocks verbatim. The console talks to OpenSearch through Dashboards, so it works even
when port 9200 is not published, which is the normal case: the published demo stacks expose 5601 and
8080 and keep OpenSearch on the internal network only.

**Dashboards REST API.** The console is backed by a real endpoint you can drive from a script. It
requires `POST` regardless of the method being proxied, an `osd-xsrf` header, and a URL-encoded
`path`:

```bash
curl -s -XPOST -H 'osd-xsrf: true' \
  'http://localhost:5601/api/console/proxy?method=GET&path=_cat/indices%3Fv%26expand_wildcards%3Dall'
```

Note the double encoding in `path`: `?` becomes `%3F` and `&` becomes `%26`, otherwise Dashboards
consumes them as its own parameters.

**Directly against OpenSearch.** If 9200 is reachable, `curl 'http://localhost:9200/...'`. Inside a
Docker Compose deployment where the port is not published:

```bash
docker exec <opensearch-container> curl -s 'http://localhost:9200/_cat/indices?v&expand_wildcards=all'
```

## Part 1: the indexes

### List everything, including the hidden indexes

```
GET _cat/indices?v&s=index&expand_wildcards=all&h=index,health,status,docs.count,docs.deleted,store.size,pri,rep
```

`expand_wildcards=all` is not optional. Two of the three Alfresco indexes are created with
`index.hidden=true`, so a plain `GET _cat/indices` silently omits them and makes it look as though
the batch indexer keeps no state. Restricted to the Alfresco indexes:

```
GET _cat/indices/alfresco*?v&s=index&expand_wildcards=all&h=index,status,docs.count,docs.deleted,store.size
```

Measured result on the live stack:

| Index | Hidden | Created by | Contents |
| --- | --- | --- | --- |
| `alfresco` | no | Content Services (`ElasticsearchInitialiser`, only when `elasticsearch.createIndexIfNotExists=true`) | one document per live node |
| `alfresco-reindex-state` | yes | batch indexer (`ElasticsearchWatermarkStore.ensureIndexExists()`) | exactly one document, the indexing cursor |
| `alfresco-reindex-dead-letter` | yes | batch indexer, at startup | one document per node the indexer gave up on; empty on a healthy system |

Confirm the hidden flag rather than trusting the table:

```
GET alfresco*/_settings?expand_wildcards=all&filter_path=*.settings.index.hidden,*.settings.index.provided_name
```

The index names are all configurable: `elasticsearch.indexName` (Content Services, default
`alfresco`), `alfresco.reindex.continuous.watermarkIndexName` and
`alfresco.reindex.dead-letter.indexName` (batch indexer). There are no aliases, so a name in the
configuration is a literal index name:

```
GET _alias?expand_wildcards=all
```

### The fourth index, which does not exist

```
GET alfresco-archive
```

This returns HTTP 404 `index_not_found_exception` on a working deployment, and that is expected.
`elasticsearch.archive.indexName` (default `alfresco-archive`) is only a query route: nothing in the
product creates the index and nothing writes to it, so v1 Search API requests scoped to
`deleted-nodes` fail with HTTP 500. Do not create it to make the error go away; an empty index turns
a loud failure into HTTP 200 with zero hits, which is indistinguishable from a genuine absence of
matches.

### The indexing cursor

```
GET alfresco-reindex-state/_doc/reindexByDate-watermark
GET alfresco-reindex-state/_mapping
```

The document id is fixed. Fields, all confirmed present at 5.7.1:

```json
{
  "schemaVersion": 1,
  "lastSuccessfulFromTimeEpochMs": 1790157117028,
  "lastSuccessfulToTimeEpochMs": 1790157732426,
  "lastRunFromTimeEpochMs": 1790157117028,
  "lastRunToTimeEpochMs": 1790157732426,
  "lastRunStatus": "COMPLETED",
  "lastRunReadCount": 837,
  "lastRunWriteCount": 837,
  "lastRunSkipCount": 0,
  "lastRunFilterCount": 0,
  "updatedAt": "2026-09-23T10:02:12.752248886Z"
}
```

`_version` and `_seq_no` in the response are meaningful: writes are guarded by optimistic
concurrency (`ifSeqNo`/`ifPrimaryTerm`), so the indexer has to be stopped before seeding the cursor
by hand. Seeding with a bare `PUT` also creates the index non-hidden, unlike the one the application
creates.

To watch the cursor advance:

```
GET alfresco-reindex-state/_doc/reindexByDate-watermark?filter_path=_version,_source.lastRunStatus,_source.lastSuccessfulToTimeEpochMs
```

### The dead-letter queue

```
GET alfresco-reindex-dead-letter/_count
GET alfresco-reindex-dead-letter/_search
```

`_count` is the operational check: anything above zero means nodes were skipped and are missing from
the index. The index is created at startup with no explicit mapping, so `GET
alfresco-reindex-dead-letter/_mapping` returns `{}` until the first record is written and dynamic
mapping fills it in. Document fields, read from `DeadLetterDocument` in the released 5.7.1 jar:
`schemaVersion`, `dbId`, `nodeRef`, `sourceCommitTimeMs`, `firstFailedAt`, `lastFailedAt`,
`failureCount`, `failureStage`, `failureType`, `failureReason`. `failureStage` is one of `READER`,
`PROCESSOR`, `METADATA_WRITER`, `PATH_WRITER`. Reader-stage records are keyed by time window
(`window:<tsFrom>-<tsTo>`) and carry a null `dbId`, because the failing page never produced a row.

Group the failures once there are any:

```
POST alfresco-reindex-dead-letter/_search
{
  "size": 0,
  "aggs": {
    "by_stage": { "terms": { "field": "failureStage.keyword" } },
    "by_type":  { "terms": { "field": "failureType.keyword" } }
  }
}
```

### Index-level configuration worth reading back

```
GET alfresco/_settings?flat_settings=true&include_defaults=true
```

Four values to check, all measured on the live index:

| Setting | Value | Source |
| --- | --- | --- |
| `index.mapping.total_fields.limit` | `7500` | set at creation from `elasticsearch.index.mapping.total_fields.limit`; the OpenSearch default is 1000 |
| `index.max_result_window` | `10000` | `elasticsearch.index.max_result_window` |
| `index.number_of_shards` | `1` | index creation |
| `index.number_of_replicas` | `1` | index creation, which is why a single-node cluster reports `yellow` |

The custom analyzers live in the same settings block:

```
GET alfresco/_settings?filter_path=**.analysis.analyzer
```

Five are defined: `locale_text_index`, `locale_text_query`, `locale_cross_text_index`,
`locale_cross_text_query` and `path_emulator`. They are what `elasticsearch.index.locale` and
`elasticsearch.index.custom.analyzer.config.files` configure, and you can exercise one directly:

```
POST alfresco/_analyze
{ "analyzer": "locale_text_index", "text": "Anadir Documentos.pdf" }
```

which returns `anadir`, `documentos.pdf`, `documentospdf`, `documentos`, `documento`, `pdf`.

## Part 2: the fields of an indexed document

### The whole mapping

```
GET alfresco/_mapping
```

About 106 KB of JSON on a stock repository. The shape matters more than the volume:

| Property of the mapping | Measured value | Consequence |
| --- | --- | --- |
| `dynamic` | `false` | anything written that is not mapped rides in `_source`, unqueryable |
| top-level properties | 951 | against a 7500 limit that accumulates and is never pruned |
| of those, `type: alias` | 273 | every `_untokenized` name is an alias, not a stored field |
| of those, carrying `copy_to` | 46 | their targets are queryable but absent from `_source` |
| field types | 345 `text`, 273 `alias`, 151 `keyword`, 62 `date`, 53 `boolean`, 35 `integer`, 22 `long`, 7 `double`, 3 `float` | |

Names and types only, which is the readable form:

```
GET alfresco/_mapping?filter_path=alfresco.mappings.properties.*.type
```

Scope it to one namespace. Remember the encoding rule below:

```
GET alfresco/_mapping?filter_path=alfresco.mappings.properties.cm%253A*.type
```

### One field at a time, and the encoding trap

Index field names are the prefixed QName with the colon percent-encoded: `cm:name` is stored as the
field literally named `cm%3Aname`. In a **URL path or query string** that literal `%` must itself be
encoded, so the field is addressed as `cm%253Aname`:

```
GET alfresco/_mapping/field/cm%253Aname
```

`GET alfresco/_mapping/field/cm%3Aname` returns `{"alfresco":{"mappings":{}}}`, an empty result with
HTTP 200 and no error, which is the single easiest way to conclude wrongly that a field does not
exist. In a **JSON request body** no extra encoding is needed: write `"cm%3Aname"`.

The mapping carries the decoding back in `meta`, so you never have to guess:

```json
"cm%3Aname": {
  "type": "text",
  "copy_to": ["cm%3Aname_untokenized"],
  "meta": { "DecodedQualifiedName": "cm:name" },
  "analyzer": "locale_text_index",
  "search_analyzer": "locale_text_query"
}
```

To go the other way, from a QName to its field name, filter on that metadata:

```bash
curl -s 'http://localhost:9200/alfresco/_mapping' \
  | jq -r '.alfresco.mappings.properties | to_entries[]
           | select(.value.meta.DecodedQualifiedName == "cm:name") | .key'
```

### Field capabilities: what is searchable and what is aggregatable

```
GET alfresco/_field_caps?fields=*
```

More useful than `_mapping` for query design, because it states `searchable` and `aggregatable` per
field and resolves aliases to their concrete type. A `text` field reports
`searchable: true, aggregatable: false`, which is exactly why sorting or faceting on it is dropped
with `Ignorning sort on field <field>` (the misspelling is in the product source). Its
`_untokenized` alias reports `keyword` with `aggregatable: true`.

```
GET alfresco/_field_caps?fields=cm%253Aname,cm%253Aname_untokenized,ANCESTOR
```

### The complete field list through the Dashboards API

Dashboards has a dedicated endpoint that returns the flattened field list the Discover UI uses, which
is the most direct answer to "all the fields of an indexed document":

```bash
curl -s 'http://localhost:5601/api/index_patterns/_fields_for_wildcard?pattern=alfresco' | jq '.fields | length'
```

It returned 952 entries: the 951 top-level properties plus the `PATH.keyword` subfield. Each entry
carries `name`, `type`, `esTypes`, `searchable`, `aggregatable` and `readFromDocValues`. Aliases are
included and resolved. Useful slices:

```bash
# every aggregatable field, which is the set you can sort and facet on
curl -s 'http://localhost:5601/api/index_patterns/_fields_for_wildcard?pattern=alfresco' \
  | jq -r '.fields[] | select(.aggregatable) | .name' | sort

# the non-model fields: everything that is not a content-model property
curl -s 'http://localhost:5601/api/index_patterns/_fields_for_wildcard?pattern=alfresco' \
  | jq -r '.fields[].name' | grep -v '%3A' | sort
```

That second command returns the 32 structural fields:

```
ALIVE  ANAME  ANCESTOR  APATH  ASPECT  ASPECT_untokenized
CATEGORY_ANCESTOR  CONTENT_INDEXING_LAST_UPDATE  DENIED  DENIED_untokenized
METADATA_INDEXING_LAST_UPDATE  NPATH  OWNER  OWNER_untokenized  PARENT
PATH  PATH.keyword  PATH_INDEXING_LAST_UPDATE  PNAME  PRIMARYPARENT
PROPERTIES  PROPERTIES_untokenized  READER  READER_untokenized
SITE  SITE_untokenized  STANDARD_ANCESTOR  TAG  TAG_untokenized
TYPE  TYPE_untokenized  UNPREFIXED_PATH  primaryHierarchy
```

There is deliberately no `DBID`, `TXID` or `ACLID` here. Those Solr transaction fields have no
counterpart in the OpenSearch document or mapping; they survive only as query grammar that the
parser drops silently.

### A real document

`_id` is the repository node id, so you can go straight from a nodeRef to the document with no
search at all. Verified on the live stack: document `c2adf612-8edd-44a6-adf6-128eddd4a6e0` matches
`GET /alfresco/api/-default-/public/alfresco/versions/1/nodes/c2adf612-8edd-44a6-adf6-128eddd4a6e0`.

```
GET alfresco/_doc/c2adf612-8edd-44a6-adf6-128eddd4a6e0
```

Or pick any document with extracted content:

```
POST alfresco/_search
{
  "size": 1,
  "query": { "bool": { "filter": [ { "exists": { "field": "cm%3Acontent" } } ] } }
}
```

The sample document had 33 keys in `_source`:

```
ALIVE  ASPECT  CATEGORY_ANCESTOR  CONTENT_INDEXING_LAST_UPDATE  DENIED
METADATA_INDEXING_LAST_UPDATE  OWNER  PARENT  PATH  PATH_INDEXING_LAST_UPDATE
PRIMARYPARENT  PROPERTIES  READER  STANDARD_ANCESTOR  TAG  TYPE  UNPREFIXED_PATH
app%3AeditInline  cm%3Aauthor  cm%3Acategories  cm%3Acontent
cm%3Acontent%2Eencoding  cm%3Acontent%2Emimetype  cm%3Acontent%2Esize
cm%3Acreated  cm%3Acreator  cm%3Adescription  cm%3Amodified  cm%3Amodifier
cm%3Aname  cm%3Atitle  primaryHierarchy  reindexingStartTime
```

Two things to read off it. The dot in `cm:content.mimetype` is encoded too, as `%2E`, because a raw
dot would make OpenSearch treat it as an object path. And `reindexingStartTime` is the one field the
batch indexer writes that live indexing does not; it is absent from the mapping, so with
`dynamic: false` it is stored and never queryable.

### The fields that are not in `_source`

Three retrieval modes give three different answers, and the difference is the point.

```
POST alfresco/_search
{
  "size": 1,
  "_source": false,
  "query": { "ids": { "values": ["c2adf612-8edd-44a6-adf6-128eddd4a6e0"] } },
  "fields": ["*"]
}
```

This returned 42 entries against the 33 in `_source`. It **adds** the alias fields
(`ASPECT_untokenized`, `TYPE_untokenized`, `cm%3Acreator_untokenized` and so on) because aliases
resolve to their target, and it **drops** five things: `DENIED`, `TAG`, `CATEGORY_ANCESTOR` and
`cm%3Acategories`, whose values are empty arrays that `fields` omits, and `reindexingStartTime`,
which is unmapped. That last omission is a handy test: a field present in `_source` and absent from
`fields` is a field outside the mapping.

Neither mode shows `ANCESTOR`. It is a `copy_to` target of `STANDARD_ANCESTOR` and
`CATEGORY_ANCESTOR`, so it is fully queryable while being written by no indexer and stored in no
`_source`. `docvalue_fields` reads it out of doc values:

```
POST alfresco/_search
{
  "size": 1,
  "_source": false,
  "query": { "ids": { "values": ["c2adf612-8edd-44a6-adf6-128eddd4a6e0"] } },
  "docvalue_fields": ["ANCESTOR", "STANDARD_ANCESTOR", "cm%3Aname_untokenized", "ASPECT_untokenized"]
}
```

which returned `ANCESTOR` with the same five ancestor ids as `STANDARD_ANCESTOR`. List the 46
`copy_to` relationships so you know which fields behave this way:

```bash
curl -s 'http://localhost:9200/alfresco/_mapping' \
  | jq -r '.alfresco.mappings.properties | to_entries[]
           | select(.value.copy_to) | "\(.key) -> \(.value.copy_to | join(","))"'
```

Forty-four of them are a `text` field feeding its own `_untokenized` keyword twin. The two
structural ones are `STANDARD_ANCESTOR` and `CATEGORY_ANCESTOR` feeding `ANCESTOR`, and
`UNPREFIXED_PATH` feeding `PATH`.

### Fields that are mapped and never populated

```
POST alfresco/_search
{ "size": 0, "aggs": { "site": { "terms": { "field": "SITE" } } } }
```

Returns no buckets. `SITE` is in the mapping, no indexer writes it, and the query path does not read
it either: a site condition is resolved through `SiteService` and emitted as a term query on
`primaryHierarchy`. `ANAME`, `APATH`, `NPATH` and `PNAME` are in the same position. Confirm any of
them in one call:

```
POST alfresco/_search
{
  "size": 0,
  "aggs": {
    "SITE":  { "value_count": { "field": "SITE" } },
    "ANAME": { "value_count": { "field": "ANAME" } },
    "APATH": { "value_count": { "field": "APATH" } },
    "NPATH": { "value_count": { "field": "NPATH" } },
    "PNAME": { "value_count": { "field": "PNAME" } }
  }
}
```

### Counting the mapped fields against the limit

Mapping growth is additive and never pruned, so the headroom against
`index.mapping.total_fields.limit` is worth a periodic check. There is no console-only way to count,
so this one needs a shell:

```bash
curl -s 'http://localhost:9200/alfresco/_mapping' \
  | jq '.alfresco.mappings.properties | length'          # 951 on a stock repository

curl -s 'http://localhost:9200/alfresco/_settings?flat_settings=true&include_defaults=true' \
  | jq -r '.alfresco.settings["index.mapping.total_fields.limit"]'   # 7500

# breakdown by type, including how many are aliases rather than real fields
curl -s 'http://localhost:9200/alfresco/_mapping' \
  | jq -r '.alfresco.mappings.properties | to_entries
           | group_by(.value.type)[] | "\(.[0].value.type // "object") \(length)"' | sort -k2 -nr
```

## Gotchas, collected

| Symptom | Cause |
| --- | --- |
| `_cat/indices` shows only `alfresco` | the state and dead-letter indexes are `index.hidden=true`; add `expand_wildcards=all` |
| `_mapping/field/cm%3Aname` returns an empty mapping, HTTP 200 | field names contain a literal `%3A`, so URL paths need `cm%253Aname`; JSON bodies do not |
| a field is in `_mapping` but missing from a document's `fields` | its value is an empty array, or it is a `copy_to` target; use `docvalue_fields` |
| a field is in `_source` but missing from `fields` | it is not in the mapping, and `dynamic: false` means it never will be |
| `alfresco-archive` is missing and archive queries return HTTP 500 | nothing creates or fills that index; the remedy is to stop issuing the query, not to create it |
| cluster health is `yellow` on a single node | `number_of_replicas: 1` with one node, so replicas stay unassigned |
| Dashboards proxy returns the wrong thing | `?` and `&` inside `path` must be sent as `%3F` and `%26` |

## Provenance

Measured on the live stack: the index inventory and hidden flags, index settings and analyzer names,
the watermark document and its mapping, the dead-letter index existing with an empty mapping, the
mapping shape (951 properties, 273 aliases, 46 `copy_to`, type counts), the 952-entry Dashboards
field list, the 33 `_source` keys and 42 `fields` entries of a real document, `ANCESTOR` via
`docvalue_fields`, `_id` matching the repository node id, the `%3A` double-encoding behaviour, and
the Dashboards `console/proxy` and `_fields_for_wildcard` endpoints.

Read from source rather than measured: the `DeadLetterDocument` field list and `FailureStage` values
(field names verified present in the released 5.7.1 jar, the per-field semantics read from the
connector sources), the reason `SITE` is never populated, and the optimistic-concurrency guard on
watermark writes.
