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

The file the image ships lists 60 namespaces, all of them Alfresco's own. Yours is not among
them.

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

## The file replaces the map, it does not extend it

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

So the file has to be complete: every namespace the repository knows, not just yours.

## Generating a complete map

The repository is the only component that knows every deployed model, and it will hand the whole
map over. [model-ns-prefix-mapping](https://github.com/AlfrescoLabs/model-ns-prefix-mapping) is a
small Alfresco Labs addon (Apache-2.0, ACS 7.0 and later) that adds one read-only WebScript
returning exactly the JSON structure the indexer consumes, for every namespace in the dictionary
including yours.

It is not part of the product and carries no support. It reads the dictionary and writes nothing.

### 1. Install the addon in the repository

Download the release JAR and check it:

```bash
mkdir -p tools/addons
curl -sSL -o tools/addons/model-ns-prefix-mapping-1.2.0.jar \
  https://github.com/AlfrescoLabs/model-ns-prefix-mapping/releases/download/1.2.0/model-ns-prefix-mapping-1.2.0.jar
shasum -a 256 tools/addons/model-ns-prefix-mapping-1.2.0.jar
# 3d4a3e34397ee7af8f9f097a0c7539744050e59edafb89db66ad6cc0f5fceede
```

`full-stack` builds its own repository image and already has a directory for this. Move the JAR
into it and rebuild:

```bash
mv tools/addons/model-ns-prefix-mapping-1.2.0.jar full-stack/alfresco/modules/jars/
docker compose build alfresco
```

The other three deployments run the published image, which carries an exploded webapp, so the JAR
goes in as a bind mount on the `alfresco` service:

```yaml
  alfresco:
    volumes:
      - ../tools/addons/model-ns-prefix-mapping-1.2.0.jar:/usr/local/tomcat/webapps/alfresco/WEB-INF/lib/model-ns-prefix-mapping-1.2.0.jar:ro
```

`minimal-tls` and `solr-to-opensearch-migration` already declare `volumes` on that service.
Append the mount to the existing list rather than adding a second `volumes` key, which YAML
rejects.

Either way the repository has to be recreated, since a module is registered at startup:

```bash
docker compose up -d --force-recreate alfresco
```

On a Tomcat installation rather than a container, the equivalent is to stop Alfresco, copy the
JAR into `tomcat/webapps/alfresco/WEB-INF/lib`, and start it again.

### 2. Fetch the map

Deploy your model first, so it is in the dictionary the addon reads. Then, with the stack
running:

```bash
mkdir -p minimal/config
tools/fetch-prefix-map.sh > minimal/config/prefixes.json
```

The script calls `GET /alfresco/s/model/ns-prefix-map` as an administrator and refuses to write
a map that is missing Alfresco's own namespaces. `ALFRESCO_URL`, `ALFRESCO_USER` and
`ALFRESCO_PASSWORD` override the defaults, which are the demo stacks' `http://localhost:8080` and
`admin`/`admin`.

The dictionary is read live, so no repository restart is needed between deploying a model and
fetching the map that covers it.

The result is not the shipped file plus your namespace. On a stock Community 26.2 repository it
holds 64 entries against the shipped file's 60, and differs in both directions: the shipped file
carries four namespaces that only exist in Enterprise deployments (`abs`, `devicesync`, `hwf`,
`sync`), and misses eight that Community registers, among them the IPTC and XMP metadata
namespaces (`dc`, `photoshop`, `xmpRights`, `plus`, `Iptc4xmpCore`, `Iptc4xmpExt`, `iptcxmp`) and
`cd`. Generating the map from the repository is what makes it match the repository being indexed.

Two entries look wrong and are not: `"":""` is the dictionary's default namespace, and
`"custom.model":"custom"` is a namespace the repository bootstraps itself. The shipped file
carries both as well.

### 3. Point the indexer at it

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

Fetch the file before the indexer starts. Docker creates a directory where a bind-mounted file
does not exist, and the indexer then fails to read it.

`minimal-tls` already passes `JAVA_TOOL_OPTIONS` for the truststore and already mounts a file into
the indexer. Append the flag to that variable and the mount to the existing `volumes` list rather
than adding second keys.

Recreate the indexer after changing the file, since it is read once at startup:

```bash
docker compose rm -sf batch-indexer && docker compose up -d batch-indexer
```

The indexer never talks to the addon. Once the file exists, the addon can stay for the next model
you deploy or be unmounted again.

## Verifying

Create a node that uses the model and look for it in the index. Field names are URL-encoded, so
`hr:contractNumber` is `hr%3AcontractNumber`:

```bash
curl -s "http://localhost:9200/alfresco/_search?q=TYPE:%22hr:contract%22&pretty"
```

A match, with the custom properties in `_source` and your aspect listed in `ASPECT`, means the
namespace is resolving. Zero hits with the node present in the repository means it is not.

The log is the other half of the check. After a full cycle it should hold no `impossible to`
lines, and the job metrics should show `filterCount=0`:

```bash
docker compose logs batch-indexer | grep -e "impossible to" -e "Job metrics"
```

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

- The map was generated from the repository that will be indexed, not hand-written or copied from
  another installation.
- It was fetched after the model was deployed, so the model's namespace is in it.
- No entry was edited afterwards. A prefix that differs from the one the model declares indexes
  your data under field names no query will ask for, which fails as quietly as a missing entry.
- The indexer log has no `impossible to get prefixed name of` lines after a full cycle.
- A node of each custom type is retrievable from the index by `TYPE`.
