# One Instance, Whole Agent: a FHIR NL→SQL agent built entirely on IRIS for Health

Contemporary research on natural-language querying of clinical data has converged on one
architecture. That architecture has a platform shopping list — a FHIR repository, a SQL
projection of it, an approximate-nearest-neighbour index over embedded terminology, an
orchestrator with per-stage configuration, a durable trace, a credential store and a web
tier.

On IRIS for Health, **the entire list is already in the box.** One instance, one namespace,
one security model, one backup — plus a 109M-parameter encoder in a sidecar.

This article is a working demo (`docker compose up`, Synthea data, no PHI) and one real
quality-reporting question traced end to end through 18 production messages. Three results
from that trace are worth the read on their own:

- **No similarity threshold can define a clinical cohort.** In this run *Prediabetes* scores
  **higher** than a genuine member of the type-2 diabetes cohort. There is no cut point that
  keeps the right codes and excludes the wrong one — the ordering itself is wrong, so
  retrieval cannot be made precise by tuning. (§4.2)
- **Cosine top-1 is the wrong answer.** Asked for "a routine HbA1c check", the nearest
  neighbour is *urine screening for glucose*; the correct LOINC code ranks **third**. A
  top-1 retriever answers this entire quality measure wrongly. (§4.3)
- **The platform costs under 1% of the wall clock.** Two embedding round-trips, two vector
  searches, the guard and the execution together take ~220 ms of 26.2 seconds. The other 99%
  is four model calls — so the thing to optimise is never the database. (§4.7)

And one consequence that matters more than any of them: resolving that cohort properly rather
than with `LIKE '%diabet%'` moves the **reported quality indicator by thirteen points**, in
the flattering direction, and changes who gets called. (§5)

<!--break-->

---

## 1. Where the field is going

This is an implementation inspired by the latest papers in the field. Four research
directions shaped it, and they are worth laying out first: every stage of the pipeline below
exists to answer a specific published finding, and each one is cited.

### Direction one — stop asking the model to recall codes

A frozen frontier model asked to emit the codes defining a clinical value set returns
**48.6% codes that do not exist in the reference vocabulary**, at a set-level F1 of 0.105
[[1]](#ref1). In an OMOP cohort-construction study, the same class of model without a
terminology tool wrote vocabulary codes where concept identifiers were required: **79 of its
84 executed cohort definitions returned no patients** [[2]](#ref2).

Code recall is memorisation, and memorisation fails silently — the query runs, returns a
number, and nothing in the result says it guessed.

*Taken into this build as:* the extract pass is explicitly forbidden from emitting codes, and
told in the prompt that it does not know them.

### Direction two — terminology resolution as its own task

If the model cannot recall codes, something must resolve them. The current best formulation
treats this as **retrieval-augmented set completion**: retrieve the most similar existing
value sets from a curated corpus, then classify each candidate code in or out. A
cross-encoder fine-tuned on SapBERT reaches AUROC 0.852 and a set-level F1 of **0.298** over
a benchmark of 11,803 public VSAC value sets [[1]](#ref1) — three times zero-shot, and still
far from solved. This is the open problem of the field, not a solved preprocessing step.

*Taken into this build as:* a retrieve-then-rerank pipeline, retrieval recall-oriented
(lexical ∪ vector), with a separate reranking stage that must justify every code it keeps.
The encoder is SapBERT [[3]](#ref3), whose self-alignment objective pulls synonyms of the
same UMLS concept together — the same backbone the value-set work uses.

### Direction three — externalise expertise into tools, and record the trace

The agentic framing: vocabulary retrieval, query conventions, validation and execution all
become tools, instruction modules and checks *outside* the model, which is left to perform
bounded semantic tasks over a typed intermediate representation. Every step is recorded
[[2]](#ref2). With the terminology tool in place, median agreement with reference cohorts in
that study rises to 0.91. The authors list their observability trace as an explicit
contribution.

*Taken into this build as:* the whole production structure — one component per bounded task,
typed messages between them, and a trace that is not optional.

### Direction four — benchmarks are moving from SQL to FHIR, and from one turn to many

The lineage runs from TREQS and **EHRSQL** [[5]](#ref5) — single-turn text-to-SQL over
bespoke EHR schemas — toward two newer framings. **FHIR-AgentBench** [[6]](#ref6) re-poses
EHRSQL-style questions against actual FHIR resources, and reports that its questions need an
average of **14.5 FHIR resources each** to answer: the hard part is navigating a standardised
but deeply nested model, not writing the SQL. **EHR-ChatQA** [[7]](#ref7) makes the
interaction multi-turn and treats term mismatch as a first-class difficulty — its canonical
example is a user saying "Lopressor" where the record says "metoprolol tartrate."

*Taken into this build as:* FHIR R4 as the source of truth rather than a bespoke schema, and
a flattened projection so the SQL stays simple.

### The through-line

Across all four directions, the same conclusion: **clinical text-to-SQL is not primarily a
SQL problem.** The queries these questions need are a `COUNT(DISTINCT …)` with an `IN` list,
or a list with a derived flag, and models write those reliably. What they cannot do reliably
is decide *what goes in the IN list* — so that decision gets its own stages, and those
stages have to show their work.

The architecture is therefore settled. The question this article is about is the next one:
**what does that architecture demand of the platform underneath it**, and how many separate
products does a team normally assemble to get there?

---

## 2. The shopping list

```
CONVENTIONAL ASSEMBLY                        IRIS FOR HEALTH
7 products, 8 integrations                   1 instance, 1 sidecar

  FHIR server                              ┌──────────────────────────────────┐
      │ sync                               │  FHIR R4 repository              │
      ▼                                    │  FHIR SQL projection             │
  ETL job                                  │  VECTOR(DOUBLE,768) + HNSW       │
      │                                    │                                  │
      ▼                                    │  ┌────────────────────────────┐  │
  warehouse ──────┐                        │  │ Interoperability           │  │
      │           │                        │  │ production = agent runtime │  │
      ▼           ▼                        │  │ service · process ·        │  │
  vector DB ──► orchestration              │  │ 5 traced operations        │  │
                 framework                 │  │ settings · pool · retry ·  │  │
      ▲           │                        │  │ resend                     │  │
      │           ▼                        │  └────────────────────────────┘  │
  secret store   trace /                   │                                  │
      │          observability             │  message bank = the trace        │
      │           ▲                        │  Credentials = the key store     │
      └──────► web tier                    │  CSP page    = the web tier      │
                                           └──────────────────────────────────┘
                                                        ▲
                                                        │ loopback, no exposed port
                                           ┌────────────┴─────────────┐
                                           │ sidecar: SapBERT 109M,   │
                                           │ CPU + vendor SDK         │
                                           └──────────────────────────┘
```

The difference is the arrows on the left. Each one is a sync job, a schema contract and a
failure mode somebody owns. On the right, the terminology vectors and the patient facts are
tables in the same engine, so there is nothing to keep in step — and the orchestrator, the
trace and the key store are not products that were chosen, they are the production itself.

| the design needs | IRIS for Health supplies | what it replaced |
|---|---|---|
| a FHIR R4 repository to query | the FHIR server, same namespace | a separate FHIR product and an export path |
| a flat, typed schema for the SQL pass | FHIR SQL projection over the live repository | ETL into a warehouse, on a schedule |
| ANN search over embedded terminology | `VECTOR(DOUBLE,768)` + `AS HNSW` + `VECTOR_COSINE` | a vector database, and a sync pipeline to it |
| retrieval joined to clinical facts | one `SELECT`, one engine, one transaction | application-side joins across two stores |
| sequence model calls and tool calls | a business process over typed messages | an agent framework |
| a different model per stage, changeable | one business operation per pass; model is a setting | config plumbing and a redeploy |
| concurrency, queueing, retry, replay | pool size, invocation mode, failure timeout, *Resend* | a queue and a worker tier |
| a durable, reviewable record of every step | the message bank — Message Viewer, searchable | a tracing service, and instrumentation code |
| somewhere safe for the API key | a Credentials entry, referenced not copied | a secret manager, plus an injection path |
| a chat surface | a CSP page in the same instance | a front-end app and its own deployment |
| **a biomedical text encoder** | *— not in the box* | **SapBERT in a sidecar: 109M params, CPU** |

One row has no IRIS answer, and it is the honest one: the encoder. SapBERT runs in a small
FastAPI sidecar which also holds the vendor SDK for the model calls. It shares the IRIS
container's network namespace, so IRIS reaches it on loopback with no exposed port, and it is
the single piece a customer would have to run alongside.

---

## 3. Interoperability as the agent runtime

This is the claim worth arguing hardest, because a team evaluating LangGraph or a similar
framework will not expect it. The features those frameworks exist to provide are, almost one
for one, what an Interoperability production has had for twenty years.

```
question ──► Agent.Service ──► Agent.Process ──┬──► LLM.Extract   entities, domains, synonyms
 (CSP page)   business          orchestrator    │
              service                           ├──► Embed.Op      SapBERT, 768-d      ◄─┐
                                                │                                        │ once per
                                                ├──► Vector.Op     VECTOR_COSINE + HNSW  │ concept
                                                │                                        │
                                                ├──► LLM.Rerank    keep / drop + reason ◄┘
                                                │
                                                └──► LLM.SQL       SQL over the projection
                                                         │
                                               SqlGuard ─┴─► IRIS executes ──► rows + audit trail
```

Seven production items. `Embed.Op` and `Vector.Op` are business operations rather than inline
method calls **specifically** so that the embedding round-trip and the vector search each
appear in the trace with their own request and response. Inlined they would have been
invisible — and the whole argument of the design is that each decision is inspectable.

Four properties fall out of that structure without being asked for:

- **The trace is the message log.** Every pass, every payload, every resolution decision —
  timestamped, searchable, keyed to the request. The ML4H authors [[2]](#ref2) had to build
  this; here it is where the messages already live. For clinical governance that record is
  the deliverable, not a debugging aid.
- **Per-stage model choice is a setting.** Each pass is its own operation, so the extract
  pass can run a small fast model and the rerank pass a stronger one. Swapping either is a
  production setting change — no code, no recompile. The trace records which model answered.
- **Reconfiguring the pipeline is not rewriting it.** The messages are typed classes, so
  adding a stage — a `$subsumes` operation, a PHI guard on the inbound path — is a new item
  and a new route, not a refactor of a graph definition.
- **Every channel enters the same way.** The chat page calls a business service. A REST
  client, an HL7 feed or a scheduled job would call the same one, and produce the same trace.

---

## 4. One question, traced

Everything above is argument. This section is a single real turn, pulled from the message
bank exactly as recorded — **session 282**, asked from the chat page.

The question is a quality-reporting request, phrased the way they actually arrive, typo
included:

```
Provide a list of Type 2 Diabetis patients showing who had a routine HbA1c check last year
```

It produced **18 messages** — nine request/response pairs, because there are two clinical
concepts and each gets its own embed → vector → rerank cycle:

| # | from → to | message |
|---|---|---|
| 282 | Agent.Service → Agent.Process | `Agent.Question` |
| 283/284 | Agent.Process ↔ LLM.Extract | `LLM.Request` / `LLM.Response` |
| 285/286 | Agent.Process ↔ Embed.Op | `Embed.Request` / `Embed.Response` — concept 1 |
| 287/288 | Agent.Process ↔ Vector.Op | `Vector.Request` / `Vector.Response` — concept 1 |
| 289/290 | Agent.Process ↔ LLM.Rerank | concept 1 |
| 291/292 | Agent.Process ↔ Embed.Op | concept 2 |
| 293/294 | Agent.Process ↔ Vector.Op | concept 2 |
| 295/296 | Agent.Process ↔ LLM.Rerank | concept 2 |
| 297/298 | Agent.Process ↔ LLM.SQL | `LLM.Request` / `LLM.Response` |
| 299 | Agent.Process → Agent.Service | `Agent.Answer` |

### 4.1 — extract (hdr 283/284)

`model=claude-sonnet-5 · prompt 702 tok · completion 402 tok · 4,434 ms`

```json
{
  "entities": [
    { "phrase": "Type 2 Diabetis",
      "domain": "condition",
      "synonyms": ["Type 2 Diabetes Mellitus", "T2DM",
                   "non-insulin-dependent diabetes mellitus", "NIDDM"],
      "specific_terms": [] },
    { "phrase": "routine HbA1c check",
      "domain": "observation",
      "synonyms": ["hemoglobin A1c test", "glycated hemoglobin test", "HbA1c measurement"],
      "specific_terms": ["HbA1c level", "hemoglobin A1c lab result"] }
  ],
  "dimensions": {
    "aggregation": "list_patients",
    "temporal": { "type": "window", "before": null, "after": null, "window_days": 365 },
    "group_by": null
  },
  "answerable": true,
  "reason_if_not": ""
}
```

Note what is **not** here: a single code. The prompt forbids them. What the model contributes
is the translation from how people type to how vocabularies record — including normalising
the misspelling.

### 4.2 — embed and search, concept 1 (hdr 285–288)

```
Embed.Request    purpose = candidate lookup: Type 2 Diabetis
Embed.Response   model=SapBERT  dim=768  vectors=1  latency_ms=45

Vector.Request   phrase="Type 2 Diabetis"  top_n=25
                 query_vector : 15,501 chars of encoded doubles
Vector.Response  count=10  top_similarity=0.8309  latency_ms=7
```

**45 ms to embed on CPU, 7 ms to search.** And the candidate list is where the argument of
the whole design becomes visible — verbatim from the trace, with the correct verdict added:

| cosine | code | display | rows | verdict |
|---|---|---|---|---|
| 0.8309 | 44054006 | Diabetes mellitus type 2 (disorder) | 18 | ✅ keep |
| 0.6231 | 368581000119106 | Neuropathy due to type 2 diabetes mellitus | 8 | ✅ keep |
| 0.5824 | 157141000119108 | Proteinuria due to type 2 diabetes mellitus | 14 | ✅ keep |
| 0.5747 | 90781000119102 | Microalbuminuria due to type 2 diabetes mellitus | 24 | ✅ keep |
| **0.5717** | **714628002** | **Prediabetes (finding)** | **118** | ❌ **different condition** |
| 0.5549 | 127013003 | Disorder of kidney due to diabetes mellitus | 28 | ❔ not type-specific |
| 0.5351 | 237602007 | Metabolic syndrome X (disorder) | 41 | ❌ distinct condition |
| **0.5231** | **1551000119108** | **Nonproliferative diabetic retinopathy due to type II DM** | **3** | ✅ **keep** |
| 0.5005 | 395123002 | Urine screening test for diabetes (procedure) | 84 | ❌ a test, not a diagnosis |
| 0.4529 | 80394007 | Hyperglycemia (disorder) | 6 | ❌ a finding, not the diagnosis |

Two things to read off that table.

**The typo did not matter.** "Type 2 Diabetis" still hit the correct code at 0.8309. That is
the vector layer earning its place — a lexical match on the misspelling returns nothing.

**But no threshold works.** *Prediabetes* at **0.5717** outranks *Nonproliferative diabetic
retinopathy due to type II diabetes* at **0.5231** — and the retinopathy code is a genuine
member of the cohort while prediabetes is a different clinical state. Cut at 0.55 and you
admit 118 prediabetic patients and lose a true one. There is **no cut point** that keeps all
four complication codes and excludes prediabetes, because the ordering itself is wrong.

This is not a defect in SapBERT. It is what a *similarity* metric is: "Prediabetes" and
"Type 2 Diabetes" genuinely are similar strings about related physiology. They are simply not
the same cohort, and that distinction is categorical, not metric.

### 4.3 — embed and search, concept 2 (hdr 291–294)

```
Embed.Response   model=SapBERT  dim=768  latency_ms=42
Vector.Response  count=8  top_similarity=0.5797  latency_ms=7
```

| cosine | code | display | rows | verdict |
|---|---|---|---|---|
| **0.5797** | 268556000 | Urine screening for glucose (procedure) | 83 | ❌ **wrong, and ranked first** |
| 0.5238 | 395123002 | Urine screening test for diabetes (procedure) | 84 | ❌ wrong |
| **0.4971** | **4548-4** | **Hemoglobin A1c/Hemoglobin.total in Blood** | **2,079** | ✅ **right — rank 3** |
| 0.4878 | 722161008 | Diabetic retinal eye exam (procedure) | 93 | ❌ |
| 0.4873 | Z00.00 | Encounter for general adult medical examination | 1 | ❌ |
| 0.4816 | 104091002 | Hemogram, automated… (CBC) | 167 | ❌ |
| 0.4662 | D0603 | caries risk assessment, high risk *(dental, CDT)* | 108 | ❌ |
| 0.4510 | 104375008 | Hepatitis C antibody, confirmatory test | 84 | ❌ |

**Cosine top-1 is flatly wrong.** A top-1 retrieval system answers this entire quality
measure with *"urine screening for glucose."* The right answer — the only HbA1c LOINC code in
the repository, with 2,079 results — ranks **third**. And a *dental caries risk assessment*
appears as a candidate for "routine HbA1c check," which shows vividly what similarity over a
mixed-vocabulary table pulls in.

So retrieval is deliberately recall-oriented and over-fetches, and **precision has to come
from somewhere that is not a distance.**

### 4.4 — rerank (hdr 289/290 and 295/296)

`concept 1: prompt 1,241 tok · completion 1,000 tok · 13,101 ms`
`concept 2: prompt 1,180 tok · completion 266 tok · 3,820 ms`

This is the stage that supplies the precision the vector score cannot. It sees the whole
question and must give a reason for every decision. From the chat page, as the user saw it:

**Type 2 Diabetis** — confidence high

| | code | display | why |
|---|---|---|---|
| ✓ | 44054006 | Diabetes mellitus type 2 (disorder) | Type 2 diabetes mellitus diagnosis |
| ✓ | 90781000119102 | Microalbuminuria due to type 2 diabetes mellitus | entails diagnosis |
| ✓ | 157141000119108 | Proteinuria due to type 2 diabetes mellitus | entails diagnosis |
| ✓ | 368581000119106 | Neuropathy due to type 2 diabetes mellitus | entails diagnosis |
| ✓ | 1551000119108 | Nonproliferative diabetic retinopathy due to type II DM | entails diagnosis |
| ✗ | 714628002 | — | Prediabetes is a different condition, not type 2 diabetes |
| ✗ | 127013003 | — | Kidney disorder due to diabetes — not specific to type 2, could be type 1 |
| ✗ | 237602007 | — | Metabolic syndrome is a distinct condition |
| ✗ | 395123002 | — | Procedure code, not a diagnosis of diabetes |
| ✗ | 80394007 | — | Hyperglycemia is a sign/finding, not type 2 diabetes diagnosis |

> **note:** Excluded 'Disorder of kidney due to diabetes mellitus' as it is not type-specific
> and could apply to type 1 diabetes patients, which would overcount the type 2 cohort.

**routine HbA1c check** — confidence high

| | code | display | why |
|---|---|---|---|
| ✓ | 4548-4 | Hemoglobin A1c/Hemoglobin.total in Blood | HbA1c lab test |
| ✗ | 268556000 | — | urine glucose screening, not HbA1c |
| ✗ | 395123002 | — | urine diabetes screening, not HbA1c |
| ✗ | 722161008 | — | diabetic eye exam, unrelated |
| ✗ | Z00.00 | — | general exam encounter, not HbA1c specific |
| ✗ | 104091002 | — | CBC panel, not HbA1c |
| ✗ | D0603 | — | dental caries risk, unrelated |
| ✗ | 104375008 | — | hepatitis C test, unrelated |

Both directions of the judgement are recorded, each with a reason: four complication codes
pulled **in** because they entail the diagnosis, prediabetes pushed **out** because it is a
different clinical state, and the cosine top-1 rejected in favour of rank 3.

### 4.5 — SQL (hdr 297/298)

`prompt 1,329 tok · completion 413 tok · 4,657 ms`

The SQL pass never sees a vocabulary. It is handed the resolved codes as literals and the
live schema, read from `INFORMATION_SCHEMA` at runtime:

```
Question: Provide a list of Type 2 Diabetis patients showing who had a routine HbA1c check last year

Schema:
INT_FHIRSQLLLM_Projection.Fact: ID, Code, CodeSystem, Display, FactDate, FactDay,
                                FactType, PatientId, ResourceId, Status,
                                ValueQuantity, ValueUnit

One row per (resource, coding). FactType is one of: condition, procedure, medication,
observation, immunization, allergy. Filter on FactType AND Code.
DATES: FactDate is a STRING (ISO-8601 with offset) -- fine to display, fine to compare
with <= and >=, but date FUNCTIONS over it return no rows. FactDay is the same date as a
real date type. Use FactDay for all arithmetic...

Resolved codes:
  "Type 2 Diabetis" (condition) = '44054006', '90781000119102', '157141000119108',
                                  '368581000119106', '1551000119108'
  "routine HbA1c check" (observation) = '4548-4'
```

And the query it wrote:

```sql
SELECT DISTINCT c.PatientId AS PatientId,
       CASE WHEN EXISTS (
              SELECT 1 FROM INT_FHIRSQLLLM_Projection.Fact o
              WHERE  o.PatientId = c.PatientId
                AND  o.FactType  = 'observation'
                AND  o.Code IN ('4548-4')
                AND  YEAR(o.FactDay) = YEAR(CURRENT_DATE) - 1)
            THEN 'Yes' ELSE 'No' END AS HadRoutineHbA1cLastYear
FROM   INT_FHIRSQLLLM_Projection.Fact c
WHERE  c.FactType = 'condition'
  AND  c.Code IN ('44054006', '90781000119102', '157141000119108',
                  '368581000119106', '1551000119108')
```

Every cohort member appears, with the check as a derived column. It also resolved "last year"
to the previous *calendar* year and said so in the column name.

### 4.6 — the answer (hdr 299)

**36 rows · 19 Yes / 17 No · 26,235 ms · models: claude-sonnet-5**

| PatientId | HadRoutineHbA1cLastYear |
|---|---|
| bea259a5-5f7a-fbba-59ed-2a65c333dee5 | No |
| 99e4e110-a6d4-40f0-5c29-bc76e91c5e72 | No |
| 81459c20-fe55-9452-f9f9-d72961743ffc | Yes |
| 8e9441b3-1df1-03f9-349f-0bcf7a45c584 | Yes |
| 21dbf5be-f9aa-4762-ad52-8bbe945df48b | Yes |
| 5399dec7-df22-d315-ca17-6203e757600c | Yes |
| ddfac38c-a595-4f62-08d9-b8e1122f48d0 | No |
| 1ae4a0f2-d469-65e5-7961-98c24d7f8e0f | No |
| 58997ef2-dd4a-5945-e03f-3fe87fb948dd | Yes |
| 01c6eaaf-9f5a-8d40-f6eb-20c0108f9eb9 | No |
| … | *26 further rows* |

The output is a worklist: seventeen named diabetic patients with no HbA1c last year, ready to
be called.

### 4.7 — where the 26 seconds went

| stage | runs in | latency | share |
|---|---|---|---|
| extract | *model call* | 4,434 ms | 16.9% |
| **embed** × 2 | **sidecar, loopback** | **87 ms** | **0.3%** |
| **vector search** × 2 | **IRIS SQL** | **14 ms** | **0.1%** |
| rerank × 2 | *model calls* | 16,921 ms | 64.5% |
| SQL generation | *model call* | 4,657 ms | 17.8% |
| guard + execute + assemble | **IRIS** | ~122 ms | 0.5% |
| **total** | | **26,235 ms** | 100% |

Everything the platform does — two embedding round-trips, two vector searches over the
terminology, the guard, the execution, assembling the audit record — costs **about 220 ms of
26.2 seconds, under 1%.** The other 99% is waiting on four model calls.

Two consequences. First, the retrieval machinery is effectively free, so there is no
performance reason to cut corners on it: widening the candidate set or adding a `$subsumes`
check costs milliseconds against a 17-second rerank. Second, **the optimisation target is
obvious and it is not the database** — it is the rerank pass, which is exactly the component
that is a swappable production setting.

---

## 5. Why this is the whole argument

### First, why a BI tool cannot take this request

Nothing in that question is hard SQL. What is hard is everything that has to be decided
*before* the SQL can be written — and a BI tool has no stage in which to decide it.

| what the request needs | why a BI tool stops | what the agent does |
|---|---|---|
| **a diabetic cohort** | "Type 2 diabetes" is not one code — it is a value set, and the judgement runs in *both directions at once*. Complication codes such as *Neuropathy due to type 2 diabetes mellitus* must be **included** (a patient carrying only that code is diabetic), while *Prediabetes* must be **excluded**. No filter expression encodes both, and no similarity threshold separates them — see §4.2. | resolves a value set, with a recorded reason for every code in and out |
| **"showing who had"** | the output is one row per cohort member with a derived Yes/No column, not a filtered list. A dashboard filters rows that exist; it cannot easily keep the patients for whom the event is *absent* — and those are the whole point of the report. | `CASE WHEN EXISTS (…)` per patient |
| **"a routine HbA1c check"** | the phrase matches no display string. `LIKE '%HbA1c%'` returns nothing, and cosine top-1 returns *urine screening for glucose* — see §4.3. | resolves to LOINC 4548-4 |
| **"last year"** | relative to now, and ambiguous between the previous calendar year and a rolling twelve months | picks the calendar year and *says so* in the column name |

The alternative to this is not a slower query. It is a request to an analyst, who curates two
value sets and builds a model that keeps cohort members without the event — days of work, and
the code choices then disappear into a dashboard definition nobody reads again.

### And then, what that invisibility costs

A quality indicator is a number someone reports and a worklist someone acts on. Both depend
entirely on the value set behind the cohort — and that value set is normally a decision an
analyst made once, which then stays invisible for years.

Here is the same request on the same data, resolved properly, and resolved the obvious cheap
way:

| diabetes cohort | patients | Yes | No | **reported compliance** |
|---|---|---|---|---|
| resolved value set — *what the agent produced* | 36 | 19 | 17 | **52.8%** |
| naive `Display LIKE '%diabet%'` | 131 | 86 | 45 | **65.6%** |

The naive definition reports **65.6% compliance where the real figure is 52.8%** — nearly
thirteen points, and it errs in the *flattering* direction, which is the worst kind. The
mechanism is mundane: `LIKE '%diabet%'` sweeps in 92 prediabetic patients, prediabetics get
routine HbA1c monitoring, so they land almost entirely in the Yes column and pad the result.

And because this request returns a worklist, the error is not only a number on a board paper.
**The naive version hands the diabetes nurse 45 patients to chase, 28 of whom do not have
diabetes.** That is clinical time spent on the wrong people, caused by a value-set decision
nobody wrote down.

Now set that against the agent's own *debatable* call — dropping *Disorder of kidney due to
diabetes mellitus* because that code does not state which type, when the request said type 2.
A reviewer might well overrule it. It changes the cohort by three patients and the reported
figure by **under one point**.

> That contrast is the point of the design. The trace does not make the agent right; it makes
> **the consequence of each choice measurable.** The arguable decision turns out to be
> immaterial, the invisible one turns out to be worth thirteen points, and telling them apart
> takes a minute instead of an audit.

For a regulated indicator — JAWDA, HEDIS, a national diabetes audit — the recorded value set
with a reason per code *is* the auditable artefact. It is what a reviewer needs in order to
sign the number off, and it is the one thing a dashboard definition has never provided.

---

## 6. Vector search where the data already is

An embedding model contains no codes. SapBERT is a text encoder: text in, vector out.
Resolution requires a stored table of `(code, system, display, vector)`, embedded once, then
searched. **That table is the terminology library**, and here it is an ordinary IRIS SQL table
with one extra column:

```objectscript
Property Embedding As %Vector(DATATYPE = "DOUBLE", LEN = 768);
```

```sql
CREATE INDEX ConceptVecIdx ON INT_FHIRSQLLLM_Terminology.Concept (Embedding)
  AS HNSW(Distance='Cosine')
```

The index is HNSW [[4]](#ref4) — the same structure the dedicated vector databases use — so
there is no retrieval-quality argument to lose. What is gained is that the concept table and
the patient facts live in the same engine, so retrieval and the clinical query are
*joinable*.

Look again at the candidate tables in §4: every row carried a **row count** — `4548-4` has
2,079, `C03.9` has 1, `714628002` has 118. That came from the same statement that did the
cosine search:

```sql
SELECT TOP 25 c.Code, c.Display, c.OccurrenceCount,
       VECTOR_COSINE(c.Embedding, TO_VECTOR(?, DOUBLE)) AS Similarity
FROM   INT_FHIRSQLLLM_Terminology.Concept c
WHERE  c.Embedding IS NOT NULL
ORDER  BY Similarity DESC
```

With a separate vector store, attaching that count is application code, a second round trip
and a consistency question. Here it is a column — and it matters to the output, because the
rerank pass sees how many patients each candidate would actually contribute.

The concept table is built *from the distinct coded values actually present in the
repository*, so every code the agent can resolve is guaranteed to exist in the data — trivial
to maintain when the vectors and the facts share a database, and a sync job when they do not.

**This deployment:** 337 synthetic patients from Synthea [[10]](#ref10) (Massachusetts, seed
20261101, 10 years of history) → 68,956 FHIR resources across 8 resource types → 199,267
projected facts → **1,220 terminology concepts** across SNOMED CT, ICD-10, LOINC, RxNorm, CVX
and CDT, of which 33 (2.7%) are lexically ambiguous.

Synthea matters to the result and not just to the licensing. It simulates each patient's life
module by module rather than sampling rows, so a diabetes diagnosis is followed by HbA1c
results and a procedure by a medication — which is the only reason a care-gap question has
anything to find. The generation scripts, the run manifest and the reproducibility caveat (a
seed is deterministic for a given build, not across builds) are in `iris/synthea/`.

---

## 7. Four bugs this question found

Worth reporting, because all four were silent, and silence is the thread running through this
whole piece.

**1. "Showing who had X" is not "who had X".** The first run of this exact question produced
an inner join — a list of the 13 patients who *did* have a check, with everyone else dropped.
Those are precisely the patients the report exists to find. Thirteen plausible rows, and the
care gap invisible. The SQL prompt now has an explicit rule: a list "showing" an event must
keep every cohort member and derive a column.

**2. The cohort depended on the phrasing.** On that same first run the rerank pass kept only
`44054006`, where the same clinical cohort asked another way kept five codes. **A reported
indicator whose denominator depends on how the request was typed is not an indicator.** The
rerank prompt now states that a disease cohort includes codes which *entail* the diagnosis,
and that the concept must resolve identically regardless of spelling or terseness.

**3. A string date defeats date arithmetic without failing.** The projection originally stored
`FactDate` as a varchar holding `2014-04-02T22:09:33+04:00`. Lexicographic `>=` orders such
strings correctly, so plain comparisons worked and looked right — but
`DATEADD('day', 90, FactDate)` returns **SQLCODE 0 and zero rows**: not an error, and not even
the `COUNT` row. Every rolling-window question answered *nothing* while appearing to run. The
fix is a real `%Date` column, `FactDay`, beside the display string, plus the schema note shown
in §4.5.

**4. FHIR choice types are easy to half-read.** The projection read
`Procedure.performedDateTime`; Synthea writes `performedPeriod`. All **36,837** procedure rows
therefore carried no date — so every temporal question about a procedure answered zero, again
without failing. After the fix, all 199,267 facts across six fact types carry a date.

All four share a signature: *the wrong answer was zero, or looked like a normal answer.* It is
the same failure mode as the 79-of-84 empty-cohort result [[2]](#ref2), reached by four
different routes — and the trace is where each one became visible.

A fifth, found separately and fixed the same way: asked about a brand name absent from the
data, one concept resolved to nothing while the other resolved fine, and the SQL pass
improvised over the gap — matching on display text against its own prompt rule and reusing a
code the reranker had explicitly rejected. **The orchestrator now abstains when any concept
resolves to zero codes, and names the one that failed.** Refusing to answer is a feature.

---

## 8. The boundaries the platform draws

| stage | what leaves the instance |
|---|---|
| extract | the question text only |
| embed | the question's noun phrases — to the loopback sidecar, no egress |
| vector | *nothing; runs in IRIS* |
| rerank | candidate **concept names** — no patient data |
| sql | question + schema + resolved codes — no patient data |
| execute | *nothing; runs in IRIS* |
| results | **never sent to any model** |

The §4 payloads are the evidence: the only clinical content that left the instance was a list
of concept *names*. The 36 patient identifiers never went near a model.

Nor does the key reach a call site. It lives in an IRIS **Credentials** entry; a method writes
it mode-600 to a volume the sidecar reads itself. It appears in no source file, no production
setting, no command line and no process list.

`Agent.SqlGuard` validates before execution: a single statement, `SELECT` only, no DML, no
DDL, no procedure calls, no chaining. It has a seven-case self-test.

For a real PHI deployment, add an inbound guard that masks identifiers in the question, set
`VerifyPeer = 1` with a real CA, and choose a vendor route with an enterprise agreement and
no-training-on-your-data terms.

---

## 9. What this does not claim

- **This is an implementation inspired by current research, and says so throughout.** The
  retrieve-then-rerank pattern is the field's, and the ML4H work [[2]](#ref2) demonstrates a
  comparable tool-mediated assembly on OMOP. What this adds is the platform mapping and the
  measurements: the same architecture built on IRIS primitives with no additional products,
  and a traced run showing where its accuracy and its latency actually come from.
- **The rerank pass is now the accuracy bottleneck** — and, per §4.7, 65% of the latency. The
  design moved the hard judgement out of retrieval into model calls. Those calls are
  auditable, which is a real gain, but they are not verified; this is the component that needs
  an evaluation set.
- **Terminology resolution remains an open problem, and this is not a resolver benchmark.**
  The best published automated value-set authoring reaches a set-level F1 of 0.298
  [[1]](#ref1); building a resolver that beats it is a different piece of work. What this
  pipeline does is make each resolution decision explicit and reviewable at query time, which
  is what a reported indicator needs.
- **Retrieval has two live layers, not three.** `ValueSet/$expand`, `CodeSystem/$subsumes`,
  `$lookup` and RxNav brand→ingredient are implemented in `Terminology.Client` with a
  `SelfTest()`, and used by the measurement harnesses — but they are **not yet called from
  the orchestrator.** That is the most valuable open item: medications are the weak spot,
  because SapBERT places a brand name nowhere near `amLODIPine 2.5 MG Oral Tablet`. It belongs
  as a traced `Expand.Op` beside `Embed.Op` and `Vector.Op`.
- **Coverage is bounded by the repository**, by design — which also means a question about a
  concept the data never recorded cannot resolve.
- **One question on Synthea.** A demonstration, not an evaluation. Synthetic data is more
  tidily coded than any real repository, and no accuracy claim is made.

What holds up without qualification is the platform claim. A contemporary clinical
natural-language agent needs a FHIR repository, a SQL projection of it, an ANN index over
embedded terminology, an orchestrator with per-stage configuration, a durable trace, a
credential store and a web tier. On IRIS for Health that is **one instance, one namespace, one
security model and one backup** — plus a 109M-parameter encoder in a sidecar, and under 1% of
the wall clock.

Not a stack assembled for agentic AI in healthcare, but one that turns out to have been
holding the right pieces all along.

---

## References

<a name="ref1"></a>**[1]** Mukherjee, S., Shu, J., Mazumder, N., Kernell, T., Wheeler, C.,
Hastings, S., Sidey-Gibbons, C. *Retrieve, Then Classify: Corpus-Grounded Automation of
Clinical Value Set Authoring.* arXiv:2604.14616 — https://arxiv.org/abs/2604.14616
*(RASC: the 48.6% nonexistent-code figure; AUROC 0.852 and set-level F1 0.298 for a SapBERT
cross-encoder against 0.105 zero-shot, over 11,803 public VSAC value sets.)*

<a name="ref2"></a>**[2]** *Separating Reasoning from Execution: A Tool-Mediated Agentic
Framework for NL2SQL and Cohort Construction on OMOP CDM.* Machine Learning for Health (ML4H)
2026, Proceedings Track. *(Externalised terminology lookup, typed intermediate representation
and recorded trace; the 79-of-84 empty-cohort result and 0.91 median agreement with the tool
in place.)*

<a name="ref3"></a>**[3]** Liu, F., Shareghi, E., Meng, Z., Basaldella, M., Collier, N.
*Self-Alignment Pretraining for Biomedical Entity Representations.* NAACL 2021, 4228–4238.
arXiv:2010.11784 — https://arxiv.org/abs/2010.11784 ·
https://github.com/cambridgeltl/sapbert
*(SapBERT. The checkpoint used here is `cambridgeltl/SapBERT-from-PubMedBERT-fulltext`.)*

<a name="ref4"></a>**[4]** Malkov, Y. A., Yashunin, D. A. *Efficient and Robust Approximate
Nearest Neighbor Search Using Hierarchical Navigable Small World Graphs.* arXiv:1603.09320 —
https://arxiv.org/abs/1603.09320 *(The structure behind `AS HNSW` in IRIS vector search.)*

<a name="ref5"></a>**[5]** Lee, G., Hwang, H., Bae, S., et al. *EHRSQL: A Practical
Text-to-SQL Benchmark for Electronic Health Records.* arXiv:2301.07695 —
https://arxiv.org/abs/2301.07695

<a name="ref6"></a>**[6]** *FHIR-AgentBench: Benchmarking LLM Agents for Realistic
Interoperable EHR Question Answering.* arXiv:2509.19319 — https://arxiv.org/abs/2509.19319
*(Reports an average of 14.5 FHIR resources needed per question.)*

<a name="ref7"></a>**[7]** *EHR-ChatQA: From Conversation to Query Execution — Benchmarking
User and Tool Interactions for EHR Database Agents.* ICLR 2026. *(Multi-turn; treats term
mismatch such as "Lopressor" vs "metoprolol tartrate" as a first-class difficulty.)*

**[8]** HL7 FHIR R4 terminology operations:
[`ValueSet/$expand`](https://hl7.org/fhir/R4/valueset-operation-expand.html) ·
[`CodeSystem/$subsumes`](https://hl7.org/fhir/R4/codesystem-operation-subsumes.html) ·
[`CodeSystem/$lookup`](https://hl7.org/fhir/R4/codesystem-operation-lookup.html) —
resolved against `tx.fhir.org/r4`.

**[9]** [RxNav / RxNorm API](https://lhncbc.nlm.nih.gov/RxNav/APIs/) — brand name to
ingredient.

<a name="ref10"></a>**[10]** Walonoski, J., Kramer, M., Nichols, J., Quina, A., Moesel, C., Hall, D.,
Duffett, C., Dube, K., Gallagher, T., McLachlan, S. *Synthea: An approach, method, and
software mechanism for generating synthetic patients and the synthetic electronic health care
record.* Journal of the American Medical Informatics Association 2018;25(3):230–238.
doi:[10.1093/jamia/ocx079](https://doi.org/10.1093/jamia/ocx079) ·
https://github.com/synthetichealth/synthea (Apache 2.0)
*(The synthetic population used throughout — **no real patient data is involved at any
point.** 337 patients, Massachusetts, seed 20261101, 10 years of history, generated with
`v3.4.0-18-ga07a65555`. Synthea simulates each patient's life module by module, which is why
the records carry the longitudinal structure the temporal and care-gap questions above
depend on. The generation scripts and the full run manifest are in `iris/synthea/`.)*

---

*Session 282 reproduced verbatim via `##class(INT.FHIRSQLLLM.Setup.Trace).Dump(282)`.
Build notes, the measurement harnesses and the list of platform gotchas are in the
repository README.*
