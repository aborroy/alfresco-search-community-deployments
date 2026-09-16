#!/usr/bin/env bash
#
# Compare a prefix map file against the namespaces the repository actually has deployed.
#
# The batch indexer resolves namespace URIs to prefixes through this file and reads it once at
# startup. A namespace the repository knows and the file does not is indexed silently and
# incompletely: a node whose own type comes from that namespace is not indexed at all. Nothing in
# the index, the job status or the dead letter queue reports it.
#
# This turns that silence into an exit status. Run it after deploying a content model, before an
# upgrade, and in CI against a staging repository.
#
# Usage, from a deployment directory with the stack running and the addon installed:
#
#   ../tools/check-prefix-map.sh                    # checks ./config/prefixes.json
#   ../tools/check-prefix-map.sh path/to/file.json
#
# Exit status:
#
#   0  every namespace the repository knows is in the file, with the same prefix
#   1  at least one namespace is missing or mapped to a different prefix
#   2  could not run the check at all
#
# Environment:
#
#   ALFRESCO_URL       repository base URL, default http://localhost:8080
#   ALFRESCO_USER      administrator user, default admin
#   ALFRESCO_PASSWORD  administrator password, default admin
#
# Requires curl and python3. See docs/custom-content-models.md.

set -euo pipefail

PREFIX_FILE="${1:-config/prefixes.json}"

ALFRESCO_URL="${ALFRESCO_URL:-http://localhost:8080}"
ALFRESCO_USER="${ALFRESCO_USER:-admin}"
ALFRESCO_PASSWORD="${ALFRESCO_PASSWORD:-admin}"

ENDPOINT="${ALFRESCO_URL%/}/alfresco/s/model/ns-prefix-map"

if [ ! -f "$PREFIX_FILE" ]; then
    echo "$PREFIX_FILE does not exist." >&2
    echo "Generate it with tools/fetch-prefix-map.sh, or pass the path as an argument." >&2
    exit 2
fi

for required in curl python3; do
    if ! command -v "$required" >/dev/null 2>&1; then
        echo "$required is required and was not found." >&2
        exit 2
    fi
done

live="$(mktemp)"
trap 'rm -f "$live"' EXIT

if ! status="$(curl -sS -o "$live" -w '%{http_code}' \
    -u "${ALFRESCO_USER}:${ALFRESCO_PASSWORD}" "$ENDPOINT")"
then
    status="000"
fi

case "$status" in
    200) ;;
    401|403)
        echo "$ENDPOINT rejected ${ALFRESCO_USER} with HTTP $status." >&2
        echo "The endpoint requires an administrator; set ALFRESCO_USER and ALFRESCO_PASSWORD." >&2
        exit 2
        ;;
    404)
        echo "$ENDPOINT returned HTTP 404." >&2
        echo "The model-ns-prefix-mapping addon is not installed in this repository." >&2
        echo "See docs/custom-content-models.md." >&2
        exit 2
        ;;
    000)
        echo "Could not reach $ENDPOINT. Is the stack running?" >&2
        exit 2
        ;;
    *)
        echo "$ENDPOINT returned HTTP $status." >&2
        exit 2
        ;;
esac

exec python3 - "$live" "$PREFIX_FILE" <<'PYTHON'
import json
import sys


def fail_to_run(message):
    print(message, file=sys.stderr)
    raise SystemExit(2)


def load(path, label):
    try:
        with open(path, encoding="utf-8") as handle:
            document = json.load(handle)
    except (OSError, ValueError) as error:
        fail_to_run("%s is not readable JSON: %s" % (label, error))
    mapping = document.get("prefixUriMap") if isinstance(document, dict) else None
    if not isinstance(mapping, dict):
        fail_to_run("%s has no prefixUriMap object." % label)
    return mapping


def show(uri, prefix):
    """The dictionary's default namespace is the empty string in both the endpoint's response and
    the shipped file, so print something visible rather than blank space."""
    return "%s -> %s" % (uri or "(default namespace)", prefix or "(no prefix)")


live_path, file_path = sys.argv[1], sys.argv[2]

live = load(live_path, "The repository response")
configured = load(file_path, file_path)

# A map without cm and sys is not a usable map at all: the indexer fails its repository schema
# validation rather than merely losing custom fields, which is a different and louder failure.
core = {
    "http://www.alfresco.org/model/content/1.0": "cm",
    "http://www.alfresco.org/model/system/1.0": "sys",
}
absent_core = [uri for uri in core if uri not in configured]

missing = sorted(uri for uri in live if uri not in configured)
mismatched = sorted(uri for uri in live if uri in configured and configured[uri] != live[uri])
unknown = sorted(uri for uri in configured if uri not in live)

print("repository: %d namespaces at %s" % (len(live), live_path))
print("file:       %d namespaces in %s" % (len(configured), file_path))

if absent_core:
    print()
    print("CRITICAL: the file is missing Alfresco's own namespaces, so the indexer cannot")
    print("validate the repository schema and will index nothing at all:")
    for uri in absent_core:
        print("  %s (expected prefix %s)" % (uri, core[uri]))
    print()
    print("The file replaces the shipped map rather than extending it. Regenerate the whole map")
    print("with tools/fetch-prefix-map.sh.")

if missing:
    print()
    print("MISSING: the repository has these namespaces and the file does not. Nodes typed from")
    print("them are not indexed at all, and aspects from them are dropped, both silently:")
    for uri in missing:
        print("  " + show(uri, live[uri]))

if mismatched:
    print()
    print("MISMATCH: the file maps these to a different prefix than the repository uses. Their")
    print("data is indexed under field names no query asks for, which fails just as quietly:")
    for uri in mismatched:
        print("  %s: file says %s, repository says %s"
              % (uri or "(default namespace)", configured[uri], live[uri]))

if unknown:
    print()
    print("Present in the file and unknown to this repository (%d)." % len(unknown))
    print("Harmless, and expected if the file came from the indexer image, which ships")
    print("namespaces only Enterprise registers:")
    for uri in unknown:
        print("  " + show(uri, configured[uri]))

print()
if missing or mismatched or absent_core:
    print("FAIL: regenerate the map with tools/fetch-prefix-map.sh, then recreate the indexer.")
    print("Nodes already indexed under the current map are not revisited. See")
    print("docs/custom-content-models.md for which ones need touching or a cursor reseed.")
    sys.exit(1)

print("OK: every namespace the repository knows is in the file, with the same prefix.")
PYTHON
