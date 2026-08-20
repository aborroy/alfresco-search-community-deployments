# Alfresco Search Community deployments

Reference Docker Compose deployments of the Alfresco Content Services Community 26.2 stack
using **Alfresco Search Community**, the OpenSearch-based search module that replaces Solr 6.

Each directory is a self-contained, runnable deployment aimed at a different question. Start
with `minimal` to read the configuration, `full-stack` to get a platform you can use, and
`solr-to-opensearch-migration` to rehearse moving an existing repository across.

## The deployments

| Deployment | What it answers | Services | Search security | Persistence | Allocate |
| --- | --- | --- | --- | --- | --- |
| [`minimal`](minimal/) | What does Alfresco Search Community actually need? | Repository, DB, transform, OpenSearch, indexer | Plugin disabled | None | 6 GB |
| [`minimal-tls`](minimal-tls/) | What changes when the search backend requires TLS? | Same as `minimal` | Plugin enabled, TLS 1.3 only | None | 6 GB |
| [`full-stack`](full-stack/) | How do I run the whole platform? | Adds Share, Content App, api-explorer, nginx, Dashboards | Plugin disabled | Named volumes | 14 GB |
| [`solr-to-opensearch-migration`](solr-to-opensearch-migration/) | How do I migrate off Solr 6 without losing rollback? | Adds Solr 6 alongside, plus cursor seeding | Plugin disabled | Named volumes | 8 GB |

The "allocate" column is what to give Docker, not what the containers consume. Measured
steady-state usage after indexing is 3.6 GiB for `minimal` and 5.3 GiB for the migration
deployment. `full-stack` declares container limits summing to roughly 14 GB and has been run
successfully with 15.6 GiB allocated to Docker.

Only `full-stack` is the complete platform. The other three deliberately omit the UI layer to
keep the search configuration in the foreground.

## Quick start

```bash
git clone https://github.com/aborroy/alfresco-search-community-deployments.git
cd alfresco-search-community-deployments/minimal
docker compose up -d
```

Then open http://localhost:8080/alfresco (`admin` / `admin`) and watch the `alfresco` index
appear and fill:

```bash
curl -s "http://localhost:9200/_cat/indices?v"
```

Each deployment has its own README with the details that matter for it. `minimal-tls`
additionally requires running `./generate-certs.sh` before the first start.

## Requirements

- Docker with Compose v2 (`docker compose`, not `docker-compose`)
- Memory allocated to Docker per the table above
- Around 15 GB of disk for images
- For `minimal-tls` only: `openssl` and `keytool` from any JDK

Ports used across the deployments: 8080 (Alfresco and the proxy), 9200 (OpenSearch), 8083
(Solr 6), 8091 (indexer actuator), 5601 (Dashboards). Run one deployment at a time, since they
compete for the same ports.

## Versions

Every image tag lives in a single [`.env`](.env) at the repository root, symlinked into each
deployment directory. Bump a version once and all four follow.

| Component | Version |
| --- | --- |
| Alfresco Content Services Community | 26.2.0 |
| Alfresco Share | 26.2.1 |
| Alfresco Content App | 8.0.0 |
| Alfresco Transform Core AIO | 5.4.3 |
| Alfresco Elasticsearch Batch Indexing | 5.7.1 |
| OpenSearch and OpenSearch Dashboards | 2.19.6 |
| Alfresco Search Services (Solr 6, migration only) | 2.0.21 |
| PostgreSQL | 17.9 |

OpenSearch 3.x also works; see [docs/hxpr-coexistence.md](docs/hxpr-coexistence.md).

## Platforms

Every image used is published for both `linux/amd64` and `linux/arm64`, so architecture is not
a constraint.

**macOS and Linux:** the commands above work as written.

**Windows:** clone into WSL2 and run from there. That is the only path these deployments are
written for, and the reason is Git rather than Docker. Two Git for Windows defaults break a
native clone:

- Without symlink support, Git writes each deployment's `.env` as a text file containing the
  literal string `../.env`, and `docker compose` then fails with
  `unexpected character "/" in variable name`.
- With `core.autocrlf=true`, shell scripts are rewritten to CRLF and
  `minimal-tls/generate-certs.sh` fails immediately with `$'\r': command not found`.

A [`.gitattributes`](.gitattributes) pins line endings to LF, which handles the second problem
for fresh clones. For the first, either enable symlinks
(`git clone -c core.symlinks=true`, which needs Developer Mode) or pass the shared file
explicitly on every command:

```bash
docker compose --env-file ../.env up -d
```

Both were confirmed by cloning with the Windows defaults; neither has been tested on Windows
itself.

## Documentation

- [docs/architecture.md](docs/architecture.md): how the search tier works, the indexing
  cursor, and the configuration properties that matter
- [docs/troubleshooting.md](docs/troubleshooting.md): symptoms and causes
- [docs/hxpr-coexistence.md](docs/hxpr-coexistence.md): sharing an OpenSearch cluster with
  hxpr and Content Lake App

## A note on naming

The product is called Alfresco Search Community, but the configuration keeps the legacy
technical names throughout: the subsystem is `elasticsearch`, its properties are
`elasticsearch.*`, the shared secret property is `solr.sharedSecret`, and the text extraction
endpoint is `/alfresco/service/api/solr/textContent`. This is stable product terminology, not
a leftover to be corrected.

## Security

These are demonstration deployments. Passwords are weak and committed, TLS is off in three of
the four, and OpenSearch runs with its security plugin disabled wherever it is not the point
of the exercise. The `.env` file is tracked on purpose so the deployments run unmodified.

Nothing here is production configuration. Read
[docs/architecture.md](docs/architecture.md#hardening-checklist) before deploying anything
resembling this outside your laptop.

## License

[Apache License 2.0](LICENSE).
