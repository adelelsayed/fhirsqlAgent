#!/usr/bin/env sh
#
# Regenerate the synthetic FHIR population this demo runs on.
#
# Parameters are not invented: they are read back from the bulk-export manifest
# that Synthea wrote alongside the data we actually loaded
# (iris/data/synthea/metadata/*.json). See README.md in this directory for that
# manifest in full.
#
#   seed / clinicianSeed / referenceTime : 20261101
#   state                                : Massachusetts
#   -p 300                               -> 337 patients (see README: -p counts
#                                           living patients; deceased ones are
#                                           exported too)
#   exporter.fhir.bulk_data=true         -> NDJSON per resource type, which is
#                                           what HS.FHIRServer.Tools.DataLoader
#                                           ingests
#   exporter.years_of_history=10
#
# Usage:
#   ./generate.sh                 # writes ../data/synthea
#   ./generate.sh /some/other/dir
#
set -eu

OUT="${1:-$(cd "$(dirname "$0")/.." && pwd)/data/synthea}"
JAR="${SYNTHEA_JAR:-$(dirname "$0")/synthea-with-dependencies.jar}"

SEED=20261101
POPULATION=300
STATE=Massachusetts

if ! command -v java >/dev/null 2>&1; then
	echo "java not found. Synthea needs a JRE; this dataset was built with 17.0.20." >&2
	exit 1
fi

if [ ! -f "$JAR" ]; then
	cat >&2 <<-MSG
	Synthea jar not found at: $JAR

	Download it (about 200 MB) with:
	  curl -L -o "$JAR" \\
	    https://github.com/synthetichealth/synthea/releases/download/master-branch-latest/synthea-with-dependencies.jar

	Or set SYNTHEA_JAR to a copy you already have.

	NOTE ON REPRODUCIBILITY: a Synthea seed is deterministic for a GIVEN BUILD,
	not across builds. The data in this repository came from v3.4.0-18-ga07a65555,
	a master snapshot. A newer jar with the same seed produces a valid population
	with the same shape, but not the identical patients -- so the row counts in
	the README and the article are the ones from that build.
	MSG
	exit 1
fi

mkdir -p "$OUT"

echo "generating $POPULATION patients ($STATE, seed $SEED) into $OUT ..."
java -jar "$JAR" \
	-p "$POPULATION" \
	-s "$SEED" \
	-cs "$SEED" \
	-r "$SEED" \
	--exporter.baseDirectory "$OUT" \
	--exporter.fhir.bulk_data true \
	--exporter.years_of_history 10 \
	"$STATE"

echo
echo "done. NDJSON is in $OUT/fhir"
echo
cat <<'NEXT'
BEFORE LOADING, strip Synthea's conditional references:

    python3 ../sidecar/fix_refs.py <out>/fhir /tmp/fixed

Synthea writes references of the form

    "location": { "reference": "Location?identifier=https://github.com/..." }

which are legal inside a transaction bundle but rejected for a standalone POST
with <HSFHIRErr>MalformedRelativeReference. HS.FHIRServer.Tools.DataLoader
reports "Completed successfully" while refusing 100% of such a file, so always
load with pDisplayProgress=1. See the Gotchas section of iris/README.md.
NEXT
