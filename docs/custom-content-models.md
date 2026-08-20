# Custom content models

A custom content model needs one extra piece of indexer configuration that a stock repository
does not. Without it, nodes that use the model are indexed incompletely or not at all, and
nothing reports an error to the user who created them.

None of the four deployments here ships a custom model, so all four run correctly as they are.
Read this before deploying a model of your own on top of one of them.

## Why the indexer needs help resolving namespaces

The repository stores a property's identity as a namespace URI plus a local name. The prefix
(`cm`, `sys`, your own) lives in the model definition the dictionary loads at runtime, not in the
database.

Index field names are built from the **prefixed** name: `cm:name` becomes `cm%3Aname`. So
something has to turn `http://www.alfresco.org/model/content/1.0` into `cm`.

The batch indexer reads nodes over JDBC, straight from the repository database, where that
mapping does not exist. It resolves it through a static JSON file instead:

| Property | Default |
| --- | --- |
| `alfresco.reindex.prefixes-file` | `classpath:reindex.prefixes-file.json` |

The shipped file lists 60 namespaces, all of them Alfresco's own. Yours is not among them.

This is specific to the Community indexing path. Alfresco Search Enterprise live indexing
consumes repository events, and the repository has already resolved every prefix before it emits
one, so an Enterprise deployment never configures this file.

## What an unconfigured namespace costs

Measured on Alfresco Content Services Community 26.2.0 with batch indexing 5.7.1, using a model
in a namespace absent from the file:

| The node | What lands in the index |
| --- | --- |
| Its own type comes from your model, for example `hr:contract` | **Nothing. The node is not indexed at all.** No document, and the dead-letter index stays empty. |
| An ordinary `cm:content` node carrying one of your aspects | A document, but without the aspect's properties, and with your aspect missing from its `ASPECT` field. |

Both are silent. The failure is an `ERROR` line in the indexer log and nothing else:

```
o.a.r.processors.AlfrescoNodeProcessor : impossible to get prefixed name of contractNumber
o.a.r.processors.AlfrescoNodeProcessor : impossible to retrieve type name for node 874
```

The node counts as filtered, so `filterCount` in the job metrics rises while `readCount` and
`writeCount` look healthy. Queries then return fewer results than they should, which is the
opposite of the over-matching failure described in
[architecture.md](architecture.md#known-limitation) and just as quiet.

## The file replaces the shipped one, it does not extend it

Whatever `alfresco.reindex.prefixes-file` points at becomes the entire map. A file holding only
your namespace removes Alfresco's 60, and the indexer then cannot resolve `sys:versionMajor`
while validating the repository schema. That one fails loudly and stops everything:

```
o.a.r.processors.AlfrescoNodeProcessor : impossible to get prefixed name of versionMajor
o.s.batch.core.step.AbstractStep : Encountered an error executing step validateDbSchemaStep
java.lang.NumberFormatException: Cannot parse null string
```

Passing a single entry as a JVM system property, `-DprefixUriMap[uri]=prefix`, fails the same
way, because the system property takes precedence over the whole map rather than adding a key to
it.

So the file has to be built from the shipped one.

## Configuring it

`tools/build-prefix-map.sh` reads the map out of the pinned indexer image and adds your
namespaces. It needs Docker and nothing else; the extraction runs inside the image.

```bash
mkdir -p minimal/config
tools/build-prefix-map.sh http://example.org/model/hr/1.0=hr > minimal/config/prefixes.json
```

Pass one `URI=PREFIX` pair per namespace, and use the same prefix the model declares. A prefix
that differs from the model's indexes your data under field names no query will ask for, which
fails as quietly as a missing entry.

Mount the file and point the indexer at it:

```yaml
  batch-indexer:
    environment:
      JAVA_OPTS: -Dalfresco.reindex.prefixes-file=file:/config/prefixes.json
    volumes:
      - ./config/prefixes.json:/config/prefixes.json:ro
```

It has to be `JAVA_OPTS`, not an environment variable. The property is read through a Spring
`@PropertySource`, which resolves before the relaxed binding that turns
`ALFRESCO_REINDEX_PREFIXESFILE` into a property name.

`minimal-tls` already passes `JAVA_TOOL_OPTIONS` for the truststore and already mounts a file into
the indexer. Append the flag to that variable and the mount to the existing `volumes` list rather
than adding second keys, which YAML rejects.

Recreate the indexer after changing the file, since it is read once at startup:

```bash
docker compose rm -sf batch-indexer && docker compose up -d batch-indexer
```

## Verifying

Deploy the model, create a node that uses it, and look for your field in the document. Field
names are URL-encoded, so `hr:contractNumber` is `hr%3AcontractNumber`:

```bash
curl -s "http://localhost:9200/alfresco/_search?q=TYPE:%22hr:contract%22&pretty"
```

A match, with the custom properties in `_source` and your aspect listed in `ASPECT`, means the
namespace is resolving. Zero hits with the node present in the repository means it is not.

## Fixing nodes that were indexed before the map was correct

Correcting the file does not revisit nodes the indexer has already passed. It walks forward
through transaction commit times, so a node is only re-read when it moves ahead of the cursor.

For a handful of nodes, touching each one is enough: any metadata change, a rename included,
creates a new transaction.

For a repository where the model was in use all along, reindex from the start of history: seed
the cursor at `MIN(commit_time_ms)` and set `alfresco.reindex.continuous.maxGapAge=0`, exactly as
in [architecture.md](architecture.md#seed-from-the-database-not-from-a-date). The `cursor-seed`
service in `solr-to-opensearch-migration/compose.yaml` is a working example.

## Before you deploy a model

- Every namespace URI in every custom model is in the file, with the prefix the model declares.
- The map was built from the shipped one, not written by hand.
- The indexer log has no `impossible to get prefixed name of` lines after a full cycle.
- A node of each custom type is retrievable from the index by `TYPE`.
