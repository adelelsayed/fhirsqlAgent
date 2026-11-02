# Asking a FHIR Repository a Clinical Question, and Being Able to Check the Answer

A natural-language agent over FHIR, built entirely on IRIS for Health: FHIR SQL for the data,
vector search for the terminology, and an Interoperability production as the agent runtime.
One real question, traced through 18 messages, and what that trace shows about where these
agents actually succeed and fail.

<!--break-->

---

## 1. How clinical text-to-SQL got to where it is

The task sounds settled. A clinician asks a question in English, a model writes SQL, the
database answers. Benchmarks for it have existed for years, and the field's progression
through them is worth following, because each step moved the difficulty somewhere new.

**EHRSQL** [[5]](#ref5) set the baseline — a large, practical text-to-SQL benchmark over real
EHR schemas, built from questions actually collected from hospital staff. It established that
the hard part was not SQL syntax but schema mastery: the questions were answerable, if you knew
which of a hundred tables held what.

Then the target moved to **FHIR**. **FHIR-AgentBench** [[6]](#ref6) re-posed EHRSQL-style
questions against real FHIR resources and reported that its questions needed an average of
**14.5 FHIR resources each** to answer. The difficulty had shifted from *which bespoke table*
to *how to traverse a standardised but deeply nested model*. And **EHR-ChatQA** [[7]](#ref7)
made the interaction multi-turn while naming a difficulty the SQL-shaped benchmarks had
quietly contained all along: term mismatch. Its canonical example is a user saying "Lopressor"
where the record says "metoprolol tartrate."

That is the thread the most recent work pulls on, and it leads somewhere uncomfortable.

Asked to write out the codes that define a clinical concept, a frozen frontier model returns
**48.6% codes that do not exist in the reference vocabulary at all**, at a value-set-level F1
of 0.105 [[1]](#ref1). In an OMOP cohort-construction study, the same class of model without a
terminology tool wrote vocabulary codes where concept identifiers were required: **79 of its
84 executed cohort definitions returned no patients** [[2]](#ref2).

Read those together and the conclusion is uncomfortable because it is not about SQL at all.
The queries these questions need are a `COUNT(DISTINCT …)` with an `IN` list, or a list with a
derived flag — and models write those reliably. **What they cannot do reliably is decide what
goes in the `IN` list.** Code recall is memorisation, and memorisation fails *silently*: the
query parses, it executes, it returns a plausible number, and nothing in the output says the
codes were invented.

So the field's centre of gravity has moved from query generation to **terminology
resolution**, now treated as a research problem in its own right. The current best formulation
is retrieval-augmented set completion: retrieve the most similar existing value sets from a
curated corpus, then classify each candidate code in or out. A cross-encoder fine-tuned on
SapBERT reaches AUROC 0.852 and a set-level F1 of **0.298** over 11,803 public VSAC value sets
[[1]](#ref1) — three times zero-shot, and nobody would call it solved.

---

## 2. The architecture those papers arrived at

Different groups, different databases, broadly the same answer: stop letting the model hold
the clinical knowledge, and put that knowledge in tools around it.

The ML4H framework [[2]](#ref2) states the principle most directly. Vocabulary retrieval,
query conventions, validation and execution all become **tools, instruction modules and checks
outside the model**. The model performs bounded semantic tasks over a typed intermediate
representation, and every step is recorded. With the terminology tool in place, median
agreement with reference cohorts rises to 0.91 — from the 79-empty-cohorts baseline.

The value-set work [[1]](#ref1) contributes the shape of the resolution step itself:
**retrieve, then classify.** Retrieval is recall-oriented and casts wide; a second, separate
stage decides membership. The two jobs are not the same job, and one similarity score cannot
do both.

And SapBERT [[3]](#ref3) supplies the retriever. Its self-alignment objective pulls synonyms
of the same UMLS concept together, which is what makes "heart attack" find *myocardial
infarction* when no substring match ever will.

Put together: **bounded model tasks, terminology as an external tool, retrieve-then-rerank for
resolution, a typed intermediate representation between stages, and a recorded trace.** That
is the architecture this article implements. The citations are not decoration — each stage
below exists to answer one of the findings above.

---

## 3. Implementing it for FHIR SQL

Five stages. Four are live and traced; the fifth is built, and §9 is honest about it.

```
    "Provide a list of Type 2 Diabetis patients showing who
     had a routine HbA1c check last year"
                      │
   ┌──────────────────▼──────────────────┐
   │ 1. STEM + CONTEXT                   │  the question's words -> clinical
   │    phrase · domain · synonyms ·     │  vocabulary, read in context.
   │    specific_terms                   │  NO codes: the model is told it
   │                                     │  does not know them.
   └──────────────────┬──────────────────┘
   ┌──────────────────▼──────────────────┐
   │ 2. TERMINOLOGY RESOLUTION           │  SapBERT embedding -> VECTOR_COSINE
   │    embed -> vector search           │  over the concept table. Recall-
   │                                     │  oriented, deliberately over-fetches.
   └──────────────────┬──────────────────┘
   ┌──────────────────▼──────────────────┐
   │ 3. EXPANSION                        │  $expand is-a · $subsumes · RxNav
   │    hierarchy + brand->ingredient    │  brand->ingredient.  BUILT, NOT YET
   │                                     │  WIRED IN -- see §9.
   └──────────────────┬──────────────────┘
   ┌──────────────────▼──────────────────┐
   │ 4. RE-RANKING                       │  sees the WHOLE question + every
   │    keep / drop, with a reason       │  candidate. This is where precision
   │    per code                         │  comes from.
   └──────────────────┬──────────────────┘
   ┌──────────────────▼──────────────────┐
   │ 5. FHIR SQL                         │  resolved codes as literals, live
   │    guard -> execute                 │  schema from INFORMATION_SCHEMA,
   │                                     │  read-only validator, then IRIS runs it.
   └──────────────────┬──────────────────┘
                      ▼
            rows  +  the resolution trail
```

Three things about that chain are worth arguing for, because they are where it departs from
the papers it is built on.

**Stemming happens with the context still attached, not after it is lost.** Stage 1 does not
normalise words in isolation — it reads the whole question first. So "Type 2 Diabetis" becomes
*Type 2 Diabetes Mellitus / T2DM / NIDDM* despite the typo, and the word "surgery" in a
question about appendicitis yields *appendectomy* and *excision of appendix*, where the same
word elsewhere would not. A term normaliser placed after the question has been reduced to
keywords cannot do this; the context is already gone. This stage is also where the model is
most useful and least dangerous: it is asked to paraphrase, which it is good at, and
explicitly forbidden from emitting codes, which it is bad at.

**Resolution and expansion are separate stages, because they fail differently.** Vector search
finds concepts that *sound like* the phrase. Hierarchy expansion finds concepts that *are kinds
of* the concept — a different relation, answered by the ontology rather than by a distance.
Collapse them into one retrieval step and the second relation is never consulted. §5.2 shows
exactly what that costs: a sibling condition outscoring a true cohort member, with no
threshold able to separate them.

**Re-ranking is a stage, not a cutoff.** The cheap design is a similarity threshold. The
measurements below show why that cannot work: the ordering itself is wrong, so no cut point
admits the right codes and excludes the wrong ones. Precision has to come from something that
can read the question and give reasons — and because it gives reasons, the output is
reviewable, which turns out to matter more than the accuracy.

---

## 4. Why IRIS for Health is the right platform for this

Written out as infrastructure, that pipeline needs: a FHIR repository; a relational projection
of it that SQL can target; an approximate-nearest-neighbour index over embedded terminology;
an orchestrator that can sequence model and tool calls with per-stage configuration; a
durable, queryable record of every step; a credential store; and a web tier.

The conventional assembly is seven products with integration between each pair. On IRIS for
Health it is one instance.

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

Three IRIS capabilities carry this, each answering one requirement the architecture cannot do
without.

### Interoperability is already an agent runtime

This is the claim a team evaluating LangGraph will not expect. The features such frameworks
exist to provide are, almost one for one, what an Interoperability production has had for
twenty years: sequencing typed messages between components, per-component configuration, pool
size and queueing, retry and failure timeouts, replay via *Resend*, and a durable message log.

```
question ──► Agent.Service ──► Agent.Process ──┬──► LLM.Extract   stage 1
 (CSP page)   business          orchestrator    │
              service                           ├──► Embed.Op      stage 2  ◄─┐
                                                │                             │ once per
                                                ├──► Vector.Op     stage 2    │ concept
                                                │                             │
                                                ├──► LLM.Rerank    stage 4  ◄─┘
                                                │
                                                └──► LLM.SQL       stage 5
                                                         │
                                               SqlGuard ─┴─► IRIS executes ──► rows + trail
```

Seven production items. `Embed.Op` and `Vector.Op` are business operations rather than inline
method calls **specifically** so the embedding round-trip and the vector search each appear in
the trace with their own request and response. Inlined they would be invisible — and the whole
argument of the design is that each decision is inspectable.

What falls out for free: the ML4H authors list their observability trace as an explicit
contribution [[2]](#ref2); here it is simply where the messages already live. Per-stage model
choice is a production setting, so the cheap stage-1 pass and the expensive stage-4 pass can
run different models with no code change, and the trace records which answered. Adding a stage
— the `Expand.Op` of §9, a PHI guard on the inbound path — is a new item and a route, not a
refactor of a graph definition. And because the chat page calls a *business service*, a REST
client or an HL7 feed enters the same way and produces the same trace.

### FHIR SQL gives the model something it can actually target

The repository is queried through a FHIR SQL projection in the same namespace — no export, no
ETL schedule, no second copy to keep in step.

One deliberate choice on top of it. FHIR SQL Builder projects search parameters into
`HSFHIR_X0001_S.*`, but token values there are **`$LIST`-encoded and carry no display text**.
Querying them for a code returns 0 rows against data that plainly contains 32 matches — right
shape, wrong comparison, no error. So this demo projects one flat fact table straight from the
resource JSON:

```
INT_FHIRSQLLLM_Projection.Fact
  FactType · PatientId · ResourceId · Code · CodeSystem · Display
  FactDate · FactDay · ValueQuantity · ValueUnit · Status
```

One row per (resource, coding). Flat, plain types, one table for the SQL stage to target — and
the schema is read from `INFORMATION_SCHEMA` at runtime, so the prompt always describes the
real deployment rather than a snapshot of it.

### Vector search is not optional for terminology resolution

An embedding model contains no codes. SapBERT is a text encoder: text in, vector out.
Resolution needs a stored table of `(code, system, display, vector)`, embedded once, then
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
there is no retrieval quality to trade away. What is *gained* by having it in the database is
that the concept table and the patient facts are joinable. Every candidate the agent considers
arrives with the number of patient rows it would actually contribute, from the same statement
that computed the cosine score:

```sql
SELECT TOP 25 c.Code, c.Display, c.OccurrenceCount,
       VECTOR_COSINE(c.Embedding, TO_VECTOR(?, DOUBLE)) AS Similarity
FROM   INT_FHIRSQLLLM_Terminology.Concept c
WHERE  c.Embedding IS NOT NULL
ORDER  BY Similarity DESC
```

With a separate vector store that row count is application code, a second round trip and a
consistency question. Here it is a column — and §5.2 shows it earning its place.

The concept table is built *from the distinct coded values actually present in the
repository*, so every code the agent can resolve is guaranteed to exist in the data. Trivial
to maintain when the vectors and the facts share a database; a sync job when they do not.

**This deployment:** 337 synthetic patients from Synthea [[10]](#ref10) (Massachusetts, seed
20261101, 10 years of history) → 68,956 FHIR resources across 8 resource types → 199,267
projected facts → **1,220 terminology concepts** across SNOMED CT, ICD-10, LOINC, RxNorm, CVX
and CDT, of which 33 (2.7%) are lexically ambiguous.

Synthea matters to the result and not only to the licensing: it simulates each patient's life
module by module rather than sampling rows, so a diagnosis is followed by the tests that
should follow it. That is the only reason a care-gap question has anything to find.

---

## 5. One question, end to end

Everything above is argument. What follows is a single real turn, pulled from the message bank
exactly as recorded — **session 282**, asked from the chat page.

It is a quality-reporting request, phrased the way they actually arrive, typo included:

```
Provide a list of Type 2 Diabetis patients showing who had a routine HbA1c check last year
```

It produced **18 messages** — nine request/response pairs, because there are two clinical
concepts and each gets its own resolution cycle:

| # | from → to | stage |
|---|---|---|
| 282 | Agent.Service → Agent.Process | `Agent.Question` |
| 283/284 | Agent.Process ↔ LLM.Extract | 1 — stem + context |
| 285/286 | Agent.Process ↔ Embed.Op | 2 — concept 1 |
| 287/288 | Agent.Process ↔ Vector.Op | 2 — concept 1 |
| 289/290 | Agent.Process ↔ LLM.Rerank | 4 — concept 1 |
| 291/292 | Agent.Process ↔ Embed.Op | 2 — concept 2 |
| 293/294 | Agent.Process ↔ Vector.Op | 2 — concept 2 |
| 295/296 | Agent.Process ↔ LLM.Rerank | 4 — concept 2 |
| 297/298 | Agent.Process ↔ LLM.SQL | 5 — FHIR SQL |
| 299 | Agent.Process → Agent.Service | `Agent.Answer` |

### 5.1 Stage 1 — stem and context

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

Two concepts, each with a domain and clinical paraphrases. The typo is gone. And not a single
code — the prompt forbids them.

### 5.2 Stage 2 — resolution, and the result that decides the architecture

```
Embed.Response   model=SapBERT  dim=768  latency_ms=45
Vector.Response  count=10  top_similarity=0.8309  latency_ms=7
```

45 ms to embed on CPU, **7 ms to search**. The candidate list, verbatim from the trace, with
the correct verdict added:

| cosine | code | display | rows | verdict |
|---|---|---|---|---|
| 0.8309 | 44054006 | Diabetes mellitus type 2 (disorder) | 18 | ✅ keep |
| 0.6231 | 368581000119106 | Neuropathy due to type 2 diabetes mellitus | 8 | ✅ keep |
| 0.5824 | 157141000119108 | Proteinuria due to type 2 diabetes mellitus | 14 | ✅ keep |
| 0.5747 | 90781000119102 | Microalbuminuria due to type 2 diabetes mellitus | 24 | ✅ keep |
| **0.5717** | **714628002** | **Prediabetes (finding)** | **118** | ❌ **different condition** |
| 0.5549 | 127013003 | Disorder of kidney due to diabetes mellitus | 28 | ❔ not type-specific |
| 0.5351 | 237602007 | Metabolic syndrome X (disorder) | 41 | ❌ distinct condition |
| **0.5231** | **1551000119108** | **Nonprolif. diabetic retinopathy due to type II DM** | **3** | ✅ **keep** |
| 0.5005 | 395123002 | Urine screening test for diabetes (procedure) | 84 | ❌ a test, not a diagnosis |
| 0.4529 | 80394007 | Hyperglycemia (disorder) | 6 | ❌ a finding, not a diagnosis |

**The typo did not matter.** "Type 2 Diabetis" still hit the correct code at 0.8309 — a lexical
match on the misspelling returns nothing at all. That is stage 2 earning its place.

**But no threshold works.** *Prediabetes* at **0.5717** outranks *Nonproliferative diabetic
retinopathy due to type II diabetes* at **0.5231** — and the retinopathy code is a genuine
member of the cohort while prediabetes is a different clinical state. Cut at 0.55 and you admit
118 prediabetic patients and lose a true one. There is **no cut point** that keeps the four
complication codes and excludes prediabetes, because *the ordering itself is wrong.*

This is not a defect in SapBERT. It is what a similarity metric is: "Prediabetes" and "Type 2
Diabetes" genuinely are similar strings about related physiology. They are simply not the same
cohort — and that distinction is categorical, not metric. It is the relation stage 3
(`$subsumes`) answers and stage 4 reasons about.

The second concept makes the point harder:

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

**Cosine top-1 is flatly wrong.** A top-1 retriever answers this entire quality measure with
*"urine screening for glucose."* The right answer — the only HbA1c LOINC code in the
repository, with 2,079 results — ranks **third**. A *dental caries risk assessment* is in the
list, which shows vividly what similarity over a mixed-vocabulary table pulls in.

Note the `rows` column doing work in both tables. It comes from the same SQL statement as the
cosine score, and it is what tells the next stage that mis-keeping prediabetes costs 118
patients while the retinopathy code brings 3.

### 5.3 Stage 4 — re-ranking, with reasons

`concept 1: prompt 1,241 tok · completion 1,000 tok · 13,101 ms`
`concept 2: prompt 1,180 tok · completion 266 tok · 3,820 ms`

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

Both directions of the judgement are recorded with a reason: four complication codes pulled
**in** because they entail the diagnosis, prediabetes pushed **out** because it is a different
clinical state, and the cosine top-1 rejected in favour of rank 3.

### 5.4 Stage 5 — FHIR SQL

`prompt 1,329 tok · completion 413 tok · 4,657 ms`

The SQL stage never sees a vocabulary. It gets the resolved codes as literals and the live
schema:

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

`Agent.SqlGuard` validates it first — a single statement, `SELECT` only, no DML, no DDL, no
procedure calls, no chaining — then IRIS runs it.

**36 rows · 19 Yes / 17 No · 26,235 ms**

| PatientId | HadRoutineHbA1cLastYear |
|---|---|
| bea259a5-5f7a-fbba-59ed-2a65c333dee5 | No |
| 99e4e110-a6d4-40f0-5c29-bc76e91c5e72 | No |
| 81459c20-fe55-9452-f9f9-d72961743ffc | Yes |
| 8e9441b3-1df1-03f9-349f-0bcf7a45c584 | Yes |
| 21dbf5be-f9aa-4762-ad52-8bbe945df48b | Yes |
| … | *31 further rows* |

Seventeen named diabetic patients with no HbA1c last year: a worklist, ready to be called.

### 5.5 Where the 26 seconds went

| stage | runs in | latency | share |
|---|---|---|---|
| 1 — stem + context | *model call* | 4,434 ms | 16.9% |
| 2 — embed × 2 | **sidecar, loopback** | **87 ms** | **0.3%** |
| 2 — vector search × 2 | **IRIS SQL** | **14 ms** | **0.1%** |
| 4 — re-rank × 2 | *model calls* | 16,921 ms | 64.5% |
| 5 — SQL generation | *model call* | 4,657 ms | 17.8% |
| guard + execute + assemble | **IRIS** | ~122 ms | 0.5% |
| **total** | | **26,235 ms** | 100% |

Everything the platform does — two embedding round-trips, two vector searches, the guard, the
execution, assembling the audit record — costs **about 220 ms of 26.2 seconds, under 1%.** The
other 99% is four model calls.

Two consequences. The retrieval machinery is effectively free, so there is no performance
argument for cutting corners on it: widening the candidate set, or adding the `$subsumes` check
of stage 3, costs milliseconds against a 17-second re-rank. And **the optimisation target is
obvious and it is not the database** — it is the re-rank stage, which is exactly the component
that is a swappable production setting.

---

## 6. Why this beats a BI tool, in three specific ways

The honest comparison is not "the agent is faster." A dashboard, once built, answers its
question in milliseconds. The comparison is about what it takes to *get* the question answered,
and what you can *check* afterwards. Three angles, all visible in the run above.

### The terminology angle

Nothing in that question matches the data as typed. "Type 2 Diabetis" is misspelled; "routine
HbA1c check" appears in no display string. A BI filter needs a value set chosen in advance by
someone who knew both the clinical intent and the vocabularies.

And the value-set decision runs in **both directions at once**, which no filter expression
encodes: complication codes such as *Neuropathy due to type 2 diabetes mellitus* must be
**included**, because a patient carrying only that code is diabetic — while *Prediabetes* must
be **excluded**. §5.2 showed no similarity threshold can satisfy both requirements.

Here is what that decision is worth. The same request, on the same data, resolved properly and
resolved the obvious cheap way:

| diabetes cohort | patients | Yes | No | **reported compliance** |
|---|---|---|---|---|
| resolved value set — *what the agent produced* | 36 | 19 | 17 | **52.8%** |
| naive `Display LIKE '%diabet%'` | 131 | 86 | 45 | **65.6%** |

The naive definition reports **65.6% compliance where the real figure is 52.8%** — nearly
thirteen points, erring in the *flattering* direction. The mechanism is mundane:
`LIKE '%diabet%'` sweeps in 92 prediabetic patients, prediabetics get routine HbA1c monitoring,
so they land almost entirely in the Yes column and pad the result.

And because this request returns a worklist, the error is not only a number on a board paper.
**The naive version hands the diabetes nurse 45 patients to chase, 28 of whom do not have
diabetes.**

Now set that against the agent's own *debatable* call — dropping *Disorder of kidney due to
diabetes mellitus* because that code does not state which type, when the request said type 2.
A reviewer might well overrule it. It changes the cohort by three patients and the reported
figure by **under one point**.

> That contrast is the point. The trace does not make the agent right; it makes **the
> consequence of each choice measurable.** The arguable decision turns out to be immaterial,
> the invisible one turns out to be worth thirteen points, and telling them apart takes a
> minute instead of an audit. For a regulated indicator — JAWDA, HEDIS, a national diabetes
> audit — that recorded value set, with a reason per code, *is* the auditable artefact.

### The temporal angle

"Last year", and "showing who had" — two temporal shapes a dashboard handles badly.

The window is **relative to now and ambiguous** between the previous calendar year and a
rolling twelve months. A dashboard date filter is absolute; someone decides, hard-codes it, and
then nobody can see which was chosen. The agent picked the calendar year and **said so in the
column name** — `HadRoutineHbA1cLastYear` — a small thing that makes the choice reviewable.

Harder: the output needs **one row per cohort member with a derived Yes/No column**, not a
filtered list. A dashboard filters rows that exist; it cannot easily keep the patients for whom
the event is *absent* — and in a care gap those are the entire point. That is a correlated
`CASE WHEN EXISTS` per patient, composed at ask time.

This is also where FHIR SQL in the same engine pays. The temporal comparison is a self-join on
a flat fact table with a real date column, in one statement, in one transaction — not an
application-side join across a warehouse and a vector store with a consistency question in the
middle.

### The agility angle

The alternative to this pipeline is not a slower query — **it is a ticket.** An analyst curates
two value sets, builds a model that joins conditions to observations while keeping cohort
members without the event, decides the window, and ships a dashboard. Days. And at the end, the
clinical judgement that determined the number has disappeared into a dashboard definition
nobody reads again.

The next question — *same cohort, but who is overdue for a retinal screen?* — starts the cycle
over. New value set, new model, another ticket.

The agent answers in 26 seconds, with no new ETL, no new dashboard and no model trained, and
hands back which codes it kept, which it dropped, and why. The marginal cost of the *second*
question is 26 seconds, not another sprint. That is the agility argument, and it is worth more
than the latency one: **the bottleneck in clinical analytics has never been query execution, it
has been the queue in front of the analyst.**

---

## 7. Four bugs this question found

All four were silent, and silence is the thread running through this whole piece.

**1. "Showing who had X" is not "who had X".** The first run produced an inner join — a list of
the 13 patients who *did* have a check, with everyone else dropped. Those are precisely the
patients the report exists to find. Thirteen plausible rows, care gap invisible. The SQL prompt
now carries an explicit rule: a list "showing" an event must keep every cohort member and
derive a column.

**2. The cohort depended on the phrasing.** On that same first run the re-rank stage kept only
`44054006`, where the same clinical cohort asked another way kept five codes. **A reported
indicator whose denominator depends on how the request was typed is not an indicator.** The
re-rank prompt now states that a disease cohort includes codes which *entail* the diagnosis,
and that the concept must resolve identically regardless of spelling or terseness.

**3. A string date defeats date arithmetic without failing.** The projection originally stored
`FactDate` as a varchar holding `2014-04-02T22:09:33+04:00`. Lexicographic `>=` orders such
strings correctly, so plain comparisons worked and looked right — but
`DATEADD('day', 90, FactDate)` returns **SQLCODE 0 and zero rows**: not an error, and not even
the `COUNT` row. Every rolling-window question answered *nothing* while appearing to run. Hence
the `FactDay` column, and a schema note steering the SQL stage to it.

**4. FHIR choice types are easy to half-read.** The projection read
`Procedure.performedDateTime`; Synthea writes `performedPeriod`. All **36,837** procedure rows
therefore carried no date — so every temporal question about a procedure answered zero, again
without failing. After the fix, all 199,267 facts carry a date.

A fifth, found separately: asked about a brand name absent from the data, one concept resolved
to nothing while the other resolved fine, and the SQL stage improvised over the gap — matching
on display text against its own prompt rule and reusing a code the re-ranker had explicitly
rejected. **The orchestrator now abstains when any concept resolves to zero codes, and names
the one that failed.** Refusing to answer is a feature.

All of them share a signature: *the wrong answer was zero, or looked like a normal answer.* It
is the same failure mode as the 79-of-84 empty-cohort result [[2]](#ref2), reached by five
different routes — and the trace is where each became visible.

---

## 8. The PHI boundary

| stage | what leaves the instance |
|---|---|
| 1 — stem + context | the question text only |
| 2 — embed | the question's noun phrases — to the loopback sidecar, no egress |
| 2 — vector | *nothing; runs in IRIS* |
| 4 — re-rank | candidate **concept names** — no patient data |
| 5 — SQL | question + schema + resolved codes — no patient data |
| execute | *nothing; runs in IRIS* |
| results | **never sent to any model** |

The §5 payloads are the evidence: the only clinical content that left the instance was a list of
concept *names*. The 36 patient identifiers never went near a model.

Nor does the key reach a call site. It lives in an IRIS **Credentials** entry; a method writes
it mode-600 to a volume the sidecar reads itself. It appears in no source file, no production
setting, no command line and no process list.

For real PHI: add an inbound guard that masks identifiers in the question, set
`VerifyPeer = 1` with a real CA, and choose a vendor route with an enterprise agreement and
no-training-on-your-data terms.

---

## 9. What this does not claim

- **This is an implementation inspired by current research, and says so throughout.** The
  retrieve-then-rerank pattern is the field's, and the ML4H work [[2]](#ref2) demonstrates a
  comparable tool-mediated assembly on OMOP. What this adds is the platform mapping and the
  measurements: the same architecture on IRIS primitives with no additional products, and a
  traced run showing where its accuracy and its latency actually come from.
- **Stage 3 is built but not yet wired in.** `ValueSet/$expand`, `CodeSystem/$subsumes`,
  `$lookup` and RxNav brand→ingredient are implemented in `Terminology.Client` with a
  `SelfTest()`, and used by the measurement harnesses — but `Agent.Process` does not call them
  yet. This is the most valuable open item, and §5.2 is the argument for it: `$subsumes`
  answers the "is a kind of" relation that no distance can. Medications are where the gap shows
  most, because SapBERT places a brand name nowhere near `amLODIPine 2.5 MG Oral Tablet`. It
  belongs as a traced `Expand.Op` beside `Embed.Op` and `Vector.Op`.
- **The re-rank stage is now the accuracy bottleneck** — and, per §5.5, 65% of the latency. The
  design moved the hard judgement out of retrieval into model calls. Those calls are auditable,
  which is a real gain, but they are not verified; this is the component that needs an
  evaluation set.
- **Terminology resolution remains an open problem, and this is not a resolver benchmark.** The
  best published automated value-set authoring reaches a set-level F1 of 0.298 [[1]](#ref1);
  building a resolver that beats it is different work. What this pipeline does is make each
  resolution decision explicit and reviewable at query time, which is what a reported indicator
  needs.
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

Not a stack assembled for agentic AI in healthcare, but one that turns out to have been holding
the right pieces all along.

**Code:** <https://github.com/adelelsayed/fhirsqlAgent> — `docker compose up`, Synthea data, no
PHI.

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
and recorded trace; the 79-of-84 empty-cohort result and 0.91 median agreement with the tool in
place.)*

<a name="ref3"></a>**[3]** Liu, F., Shareghi, E., Meng, Z., Basaldella, M., Collier, N.
*Self-Alignment Pretraining for Biomedical Entity Representations.* NAACL 2021, 4228–4238.
arXiv:2010.11784 — https://arxiv.org/abs/2010.11784 ·
https://github.com/cambridgeltl/sapbert
*(SapBERT. The checkpoint used here is `cambridgeltl/SapBERT-from-PubMedBERT-fulltext`.)*

<a name="ref4"></a>**[4]** Malkov, Y. A., Yashunin, D. A. *Efficient and Robust Approximate
Nearest Neighbor Search Using Hierarchical Navigable Small World Graphs.* arXiv:1603.09320 —
https://arxiv.org/abs/1603.09320 *(The structure behind `AS HNSW` in IRIS vector search.)*

<a name="ref5"></a>**[5]** Lee, G., Hwang, H., Bae, S., et al. *EHRSQL: A Practical Text-to-SQL
Benchmark for Electronic Health Records.* arXiv:2301.07695 —
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
[`CodeSystem/$lookup`](https://hl7.org/fhir/R4/codesystem-operation-lookup.html) — resolved
against `tx.fhir.org/r4`.

**[9]** [RxNav / RxNorm API](https://lhncbc.nlm.nih.gov/RxNav/APIs/) — brand name to
ingredient.

<a name="ref10"></a>**[10]** Walonoski, J., Kramer, M., Nichols, J., Quina, A., Moesel, C.,
Hall, D., Duffett, C., Dube, K., Gallagher, T., McLachlan, S. *Synthea: An approach, method,
and software mechanism for generating synthetic patients and the synthetic electronic health
care record.* Journal of the American Medical Informatics Association 2018;25(3):230–238.
doi:[10.1093/jamia/ocx079](https://doi.org/10.1093/jamia/ocx079) ·
https://github.com/synthetichealth/synthea (Apache 2.0)
*(The synthetic population used throughout — **no real patient data is involved at any
point.** 337 patients, Massachusetts, seed 20261101, 10 years of history, generated with
`v3.4.0-18-ga07a65555`. Generation scripts and the full run manifest: `iris/synthea/`.)*

---

*Session 282 reproduced verbatim via `##class(INT.FHIRSQLLLM.Setup.Trace).Dump(282)`.*
