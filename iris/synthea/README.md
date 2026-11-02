# The synthetic population

All data in this demo is **synthetic**. No real patient data is involved at any
point, and none of it is PHI.

It was produced by [Synthea](https://github.com/synthetichealth/synthea), the
open-source synthetic patient generator from MITRE. Synthea simulates each
patient's life from birth, module by module, and exports the result as FHIR — so
the records have plausible longitudinal structure (a diabetes diagnosis followed
by HbA1c results, a procedure followed by a medication) rather than random rows.
That longitudinal structure is what makes the temporal and care-gap questions in
the article answerable at all.

## Regenerating it

```bash
./generate.sh          # or: .\generate.ps1   on Windows
```

The script needs a JRE and `synthea-with-dependencies.jar` (about 200 MB, not
committed here — the script prints the download URL).

## Provenance

The parameters in the scripts are not reconstructed from memory. Synthea's
bulk-data exporter writes a run manifest next to the data, and this is the one
from the population actually loaded into this demo —
`iris/data/synthea/metadata/2026_11_01T08_37_32Z_300_Massachusetts_5910b7b0_….json`:

```json
{
  "runID": "5910b7b0-63bd-4160-9a76-f8c1af106a08",
  "seed": 20261101,
  "clinicianSeed": 20261101,
  "referenceTime": "20261101",
  "endTime": "20261101",
  "version": "v3.4.0-18-ga07a65555",
  "patientCount": 337,
  "providerCount": 1327,
  "payerCount": 9,
  "javaVersion": "17.0.20",
  "generatorThreads": 16,
  "exporter.years_of_history": "10",
  "state": "Massachusetts",
  "modules": "*"
}
```

Two things in there are worth knowing.

**`-p 300` produced 337 patients.** The population flag counts *living* patients
at the reference date; patients who died during the simulated decade are
exported as well. Every patient count in the README and the article is 337, not
300.

**A Synthea seed is deterministic for a given build, not across builds.** This
data came from `v3.4.0-18-ga07a65555` — a master-branch snapshot, 18 commits
past the v3.4.0 tag. Running the same seed against a newer jar yields a valid
population with the same shape, but not the identical patients. So the figures
quoted elsewhere in this repository (36 type-2 diabetics, 19 with an HbA1c last
calendar year, 275 patients with gum disease) belong to *that* build. If you
regenerate, expect the same kind of answer and different numbers.

## What was exported

`exporter.fhir.bulk_data=true` gives one NDJSON file per resource type, which is
the shape `HS.FHIRServer.Tools.DataLoader` ingests. The export was:

| resource | lines | loaded into the FHIR repository |
|---|---|---|
| Observation | 137,398 | yes |
| Procedure | 36,837 | yes |
| DiagnosticReport | 33,560 | no |
| Claim | 27,149 | no |
| ExplanationOfBenefit | 27,149 | no |
| DocumentReference | 17,292 | no |
| Encounter | 17,292 | yes |
| Condition | 10,973 | yes |
| MedicationRequest | 9,857 | yes |
| Immunization | 4,970 | yes |
| SupplyDelivery | 2,596 | no |
| Medication / MedicationAdministration | 2,003 each | no |
| CarePlan / CareTeam | 1,051 each | no |
| Location | 532 | no |
| Organization / Practitioner / PractitionerRole | 531 each | no |
| Device | 523 | no |
| Patient | 337 | yes |
| Provenance | 337 | no |
| AllergyIntolerance | 327 | yes |
| ImagingStudy | 313 | no |

**68,956 resources** across the eight loaded types became **199,267 rows** in
`INT_FHIRSQLLLM_Projection.Fact` and **1,220 concepts** in
`INT_FHIRSQLLLM_Terminology.Concept`. The agent only queries coded clinical
facts, so the billing and document resources were left out; loading them would
not change any answer.

The exporter also creates an `x12/` directory, which stays empty unless the X12
exporter is enabled. It is not used here.

## Before loading: strip the conditional references

Synthea writes references of the form

```json
"location": { "reference": "Location?identifier=https://github.com/synthetichealth/synthea|051f…" }
```

That form is legal inside a FHIR **transaction bundle**, where the server
resolves it during processing. Posting the same resource on its own is rejected:

```
400  <HSFHIRErr>MalformedRelativeReference
"The reference value 'Location?identifier=…' in property (location) of
 Type 'Immunization' is malformed"
```

IRIS refused 100% of Immunization, Encounter, Procedure and MedicationRequest for
this reason **while the loader reported "Completed successfully"** — the failure
is only visible with `pDisplayProgress=1`. So run the cleaner first:

```bash
python3 ../sidecar/fix_refs.py <out>/fhir /tmp/fixed
```

It drops any `reference` whose value contains `?` and leaves ordinary `Type/id`
references intact. On this export that was **103,540 conditional references
removed from 68,956 resources.** The affected fields (chiefly `location`) are not
read by the agent, whose queries need `FactType`, `Code`, `PatientId` and
`FactDay`.

## Licence and citation

Synthea is released by The MITRE Corporation under the **Apache License 2.0**,
and its generated output carries no patient-privacy restrictions — which is the
whole reason this demo can be published at all.

If you use it, cite the paper:

> Walonoski J, Kramer M, Nichols J, Quina A, Moesel C, Hall D, Duffett C,
> Dube K, Gallagher T, McLachlan S. **Synthea: An approach, method, and software
> mechanism for generating synthetic patients and the synthetic electronic health
> care record.** *Journal of the American Medical Informatics Association*
> 2018;25(3):230–238. doi:[10.1093/jamia/ocx079](https://doi.org/10.1093/jamia/ocx079)

- Project: <https://github.com/synthetichealth/synthea>
- Wiki and module documentation: <https://github.com/synthetichealth/synthea/wiki>
