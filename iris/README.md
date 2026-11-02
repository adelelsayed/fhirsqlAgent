# FHIR NL→SQL agent on IRIS for Health

A chat page that answers clinical questions against a FHIR R4 repository by
**resolving clinical terminology as an explicit, traced stage** before any SQL is
written. Every step — each model call, the embedding round-trip, the vector
search, the codes kept and the codes dropped — is a message in the IRIS
Interoperability trace.

Built on IRIS for Health 2026.1 Community. Runs on a laptop with `docker compose up`.

```
question ──► Agent.Service ──► Agent.Process ──┬──► LLM.Extract   entities, domains, synonyms
   (CSP page)   business         orchestrator   ├──► Embed.Op      SapBERT, 768-d
                service                        ├──► Vector.Op     VECTOR_COSINE over the concept table
                                               ├──► LLM.Rerank    keep / drop, with reasons
                                               └──► LLM.SQL       SQL over the flat projection
                                                        │
                                              SqlGuard ─┴─► IRIS executes ──► rows + audit trail
```

Seven production items, each independently configurable, each traced.

---

## Why terminology is a separate stage

A model asked to write `WHERE Code = '...'` has to **recall** the code. That is
memorisation, and it fails quietly — the query runs, returns a number, and nobody
sees that the number is wrong.

Published evidence:

* A frozen frontier model emitting value-set codes returns **48.6% codes that do
  not exist** in the reference vocabulary, at a value-set-level F1 of 0.105
  ([Mukherjee et al., 2026](https://arxiv.org/abs/2604.14616)).
* In an OMOP cohort study, the same model without a terminology tool wrote
  vocabulary codes where concept identifiers were required: **79 of 84 executed
  cohort definitions returned no patients.** With the tool, median agreement with
  the reference cohorts rose to 0.91 (ML4H 2026 Proceedings Track, *Separating
  Reasoning from Execution*).

### What this deployment measured

Not quoted — run against the Synthea repository in this container.

**1. Lexical matching returns nothing for the words clinicians use.**

| phrase | `DisplayNorm LIKE '%phrase%'` | `VECTOR_COSINE` top hit |
|---|---|---|
| "gum disease" | **0 rows** | Periodontal disease — 0.772 |
| "heart attack" | **0 rows** | Myocardial infarction — 0.777 |

Neither phrase occurs in any SNOMED or ICD-10 display string. Likewise
*"appendectomy"* matches nothing: SNOMED 80146002 renders **"Excision of appendix
(procedure)"**.

**2. Where lexical matching does hit, it over-includes.**

`DisplayNorm LIKE '%periodontitis%'` returns 4 SNOMED concepts. Judged by
`CodeSystem/$subsumes` against *Chronic periodontitis* (5689008), 3 belong and 1
does not — *Asymptomatic periapical periodontitis*, a pulpal disease that shares
the word. Carried through to patient rows that is **4 of 50 rows wrong (8%)**, with
no error surfaced.

**3. Embeddings alone cannot fix it, because siblings embed closer than synonyms.**

SapBERT cosine similarity:

| pair | cosine |
|---|---|
| chronic periodontitis ↔ **aggressive** periodontitis (different disease) | **0.790** |
| heart attack ↔ myocardial infarction (*same* disease) | 0.778 |
| heart attack ↔ chronic periodontitis (unrelated) | 0.232 |

A sibling disease scores **higher** than a true synonym pair. Any similarity
threshold that admits the synonym also admits the sibling. This is the single
result that justifies the architecture: retrieval is recall-oriented and
deliberately over-fetches; **precision comes from the rerank pass, not from the
vector score.** In the live pipeline the rerank pass is the only thing supplying
it. Measured separately, `$subsumes` rejects *Asymptomatic periapical
periodontitis* where neither lexical nor vector retrieval does — which is the
argument for wiring the hierarchy client in as a second precision layer rather
than leaving one model call solely responsible.

**4. End to end.**

| question | candidates | kept | dropped | patients | latency |
|---|---|---|---|---|---|
| "How many patients have gum disease?" | 36 | 14 | 22 | **275** | 23.5 s |
| "How many patients have chronic periodontitis?" | 26 | 9 | 17 | **51** | 17.2 s |
| "How many patients were diagnosed with a heart attack?" | 53 | 4 | 8 | **13** | 10.8 s |

The drops carry clinical reasons, and they separate concepts that share a word:
gum (`K05.*`) from jaw (`M27.*`) from pulp (`K04.*`) from tooth-loss sequela
(`K08.*`). "Gum disease" (275) comes out correctly *broader* than "chronic
periodontitis" (51) — a distinction a substring match cannot make at all, since
neither phrase appears anywhere in the vocabulary.

Repeated runs of the same question returned the same 36 candidates, the same 14
kept and the same 275 patients, so the resolution is stable rather than a lucky
sample — but it is three questions on one synthetic dataset, not an evaluation.
No accuracy claim is made here; what is demonstrated is that each decision is
recorded and inspectable.

---

## Quickstart

```bash
cd iris
cp setup/password.txt.example setup/password.txt   # then edit it
docker compose up -d
```

The repository does not ship the FHIR data (it is 1.5 GB of NDJSON). Generate it
— 337 synthetic patients, no PHI — then strip the conditional references that
would otherwise be rejected silently:

```bash
synthea/generate.sh                               # needs a JRE + the Synthea jar
python3 sidecar/fix_refs.py data/synthea/fhir /tmp/fixed
docker cp /tmp/fixed fhirsqlllm:/tmp/fixed
```

See [synthea/README.md](synthea/README.md) for the exact generation parameters,
why `-p 300` yields 337 patients, and why a seed is reproducible only against the
same Synthea build.

Then set up the namespace, FHIR endpoint and SSL client config (idempotent):

```bash
docker exec fhirsqlllm iris session IRIS -U %SYS \
  "##class(INT.FHIRSQLLLM.Setup.Installer).Run()"
```

Load FHIR data, build the projection and the terminology index:

```objectscript
zn "FHIRSQLLLM"
do ##class(INT.FHIRSQLLLM.Setup.Installer).LoadResources("/home/irisowner/fhirdata")
do ##class(INT.FHIRSQLLLM.Projection.Fact).Build()
do ##class(INT.FHIRSQLLLM.Terminology.Loader).Run()
do ##class(INT.FHIRSQLLLM.Terminology.Loader).EmbedAll()
do ##class(INT.FHIRSQLLLM.Terminology.Loader).CreateVectorIndex()
```

Create a **Credentials** entry named `ClaudeAPI` in the Management Portal
(Interoperability → Configure → Credentials) with the API key as the *password*,
then hand it to the sidecar and start the production:

```objectscript
do ##class(INT.FHIRSQLLLM.Production).ExportCredential()
do ##class(INT.FHIRSQLLLM.Production).Start()
```

Chat page: `http://localhost:52773/csp/healthshare/fhirsqlllm/INT.FHIRSQLLLM.UI.Chat.cls`

Management Portal: `http://localhost:52773/csp/sys/UtilHome.csp`

Ask from the terminal instead:

```objectscript
do ##class(INT.FHIRSQLLLM.Production).Ask("How many patients have gum disease?")
```

---

## The terminology table is the library

An embedding model contains **no codes**. SapBERT is a text encoder: text in,
vector out. Resolution needs a stored table of `(code, system, display, vector)`,
embedded once, then searched. That table *is* the terminology library, and IRIS
vector search is the index over it.

`INT_FHIRSQLLLM_Terminology.Concept` is built from the **distinct coded values
actually present in the repository** — so every code the agent can resolve is
guaranteed to exist in the data, and the index stays small. `Embedding` is
`VECTOR(DOUBLE, 768)`, nullable, with an HNSW index:

```sql
CREATE INDEX ConceptVecIdx ON INT_FHIRSQLLLM_Terminology.Concept (Embedding)
  AS HNSW(Distance='Cosine')
```

Retrieval in the **live pipeline** runs two layers, cheapest first, unioned by code:

1. **lexical** — `%STARTSWITH` / `LIKE`, precise when it hits, silent when it misses
2. **vector** — `VECTOR_COSINE`, catches paraphrase and abbreviation

A third layer is **built but not yet wired into the live path**:
`Terminology.Client` implements `ValueSet/$expand` with an `is-a` filter,
`CodeSystem/$subsumes`, `CodeSystem/$lookup` against `tx.fhir.org/r4`, and RxNav
brand → ingredient, and it has a `SelfTest()`. It is used today by the
measurement harnesses in `Terminology.Loader` — `JudgeLexicalHits()` and
`CompareLexicalVsHierarchy()` — not by `Agent.Process`.

**This is the most valuable open item.** The measurements below show `$subsumes`
rejecting a wrong concept that neither lexical nor vector retrieval excludes, and
the medication case shows the cost of the gap: asked for *Norvasc*, retrieval
returns only **5** candidates, because SapBERT puts a brand name nowhere near
`amLODIPine 2.5 MG Oral Tablet`. RxNav brand → ingredient is exactly the fix, and
it belongs as a traced `Expand.Op` beside `Embed.Op` and `Vector.Op`.

### Licensing

ICD-10-CM is CDC/NCHS public domain. RxNorm is free (NLM). SNOMED CT is covered
for UAE users — the UAE has been a SNOMED International member since 2021.
**CDT (dental) is ADA-licensed and redistribution-restricted** — do not ship CDT
descriptors in any artifact.

---

## Why a flat projection and not the FHIR search tables

FHIR SQL Builder projects search parameters into `HSFHIR_X0001_S.*`, but **token
values there are `$LIST`-encoded and carry no display text.** Querying them for a
code returns 0 rows against data that plainly contains 32 matches — the shape is
right and the comparison is wrong, which is the worst kind of bug to inherit.

`INT_FHIRSQLLLM_Projection.Fact` is therefore built straight from the resource
JSON: one row per coded clinical fact, with
`FactType · PatientId · ResourceId · Code · CodeSystem · Display · FactDate ·
ValueQuantity · ValueUnit · Status`. Flat, plain types, one table for the SQL pass
to target, and the schema is read from `INFORMATION_SCHEMA` at runtime so the
prompt always describes the real deployment.

---

## Model-agnostic by construction

`INT.FHIRSQLLLM.LLM.Operation` speaks one shape — `LLM.Request` in,
`LLM.Response` out — and posts to the local sidecar, which owns the vendor
payload. Swapping model is a production setting change; swapping vendor is an edit
to one Python file. Neither touches the messages, the orchestrator, or the trace.

| component | pass | needs | max tokens |
|---|---|---|---|
| `LLM.Extract` | extract | fast, reliable structured output | 2048 |
| `LLM.Rerank` | rerank | clinical reasoning over 30–120 candidates. **Quality-critical** | 8192 |
| `LLM.SQL` | sql | strong code generation | 4096 |

The token budget is per pass because it has to be: a rerank reply over 36
candidates with a reason per code overflows 2048 tokens and truncates mid-JSON.

### Credential handling

The API key lives in an IRIS **Credentials** entry.
`Production.ExportCredential()` writes it, mode 600, to a Docker volume shared
with the sidecar, which loads it from the file itself. The key never appears in
source, in a production setting, on a command line, or in the process list — and
`iris/data/` (durable %SYS, where the credential is stored) is gitignored.

> **Do not `docker commit` or `docker save` the running container.** The
> credential lives in the IRIS database inside `iris/data/`. Git ignores it; a
> container snapshot would bake it into the image.

---

## PHI boundary

| stage | what leaves IRIS |
|---|---|
| extract | the question text only |
| embed | the question's noun phrases only (local container, no egress) |
| vector | nothing; runs in IRIS |
| rerank | candidate **concept names** — no patient data |
| sql | question + projection schema + resolved codes — no patient data |
| execute | nothing; runs in IRIS |
| results | **never sent to any model** |

No patient data reaches an LLM. For real PHI, add an inbound guard that masks or
rejects identifiers in the question, set `VerifyPeer = 1` with a real CA on the
SSL config, and use a vendor route with an enterprise agreement and
no-training-on-your-data terms (Azure OpenAI, AWS Bedrock, IBM watsonx).

`Agent.SqlGuard` rejects anything but a single read-only `SELECT` before execution
— no DML, no DDL, no procedure calls, no multiple statements. It has a 7-case
self-test.

---

## The trace comes free

The ML4H paper lists its observability trace as a contribution: every model input
and output, every tool call, every validation decision, recorded and keyed to the
request. **IRIS Interoperability already does this.** Message Viewer shows every
pass, every payload and every resolution decision, timestamped and searchable,
with no extra code.

This is why `Embed.Op` and `Vector.Op` are business operations rather than inline
method calls. Inlined they would be invisible; as operations, the message log *is*
the architecture diagram.

---

## Layout

```
iris/
  docker-compose.yml        IRIS for Health + sidecar sharing its network namespace
  sidecar/
    app.py                  FastAPI: /llm (boto3), /embed (SapBERT), /models, /health
    fix_refs.py             strips Synthea's conditional references (see Gotchas)
  setup/
    install.script          instance bootstrap
    password.txt.example    template; the real file is gitignored
  synthea/
    generate.sh             regenerate the population (POSIX)
    generate.ps1            the same, on Windows
    README.md               provenance, the run manifest, licence and citation
  src/INT/FHIRSQLLLM/
    Setup/Installer.cls     namespace, interop, FHIR endpoint, SSL client — idempotent
    Production.cls          7 items, ExportCredential(), ProbeModels(), SetModel(), Ask()
    Agent/
      Service.cls           inbound business service — every channel enters here
      Process.cls           orchestrator
      Prompts.cls           the three prompts, versioned in one place
      SqlGuard.cls          read-only validator, 7/7 self-test
      Question.cls  Answer.cls
    LLM/                    Request / Response / Operation  (vendor-neutral)
    Embed/                  Request / Response / Operation  (SapBERT, traced)
    Vector/                 Request / Response / Operation  (VECTOR_COSINE, traced)
    Terminology/
      Concept.cls           code · system · display · VECTOR(DOUBLE,768) + HNSW
      Client.cls            $expand · $subsumes · $lookup · RxNav, with SelfTest()
      Loader.cls            build, EmbedAll, CreateVectorIndex, measurement harnesses
    Projection/Fact.cls     the flat fact table
    UI/Chat.cls             CSP chat page: resolution panel, SQL, rows
```

---

## Gotchas worth knowing

These cost real time; they are documented in the classes where they bite.

* **Synthea writes conditional references** (`"reference": "Location?identifier=..."`),
  legal inside a transaction bundle and rejected for a standalone POST with
  `<HSFHIRErr>MalformedRelativeReference`. `HS.FHIRServer.Tools.DataLoader` reports
  *"Completed successfully"* while refusing 100% of the file. Run
  `sidecar/fix_refs.py` first, and always load with `pDisplayProgress=1`.
* **`DOMAIN` is a reserved word in IRIS SQL.** A property named `Domain` yields
  SQLCODE -12, and `%ExecDirect` then returns *no rows* rather than erroring.
  `Concept.cls` uses `SqlFieldName = ConceptDomain`. Check `%SQLCODE`.
* **`CREATE INDEX ... AS HNSW` needs `[ DdlAllowed ]` on the class** — otherwise
  SQLCODE -300, "DDL not enabled for class". It is not a privilege problem.
* **A DDL-created vector index does not survive a class recompile**, and
  `Distance='Cosine'` is not expressible in UDL. `CreateVectorIndex()` is
  idempotent and self-verifying; re-run it after any recompile of `Concept`.
* **Recompiling a class does not reload a running production host.** Stop and
  start the production, or you will debug code that is no longer on disk.
* **XData production settings override a class `InitialExpression`** — and a
  setting whose property is not in `SETTINGS` is silently ignored.
* **`EnsLib.HTTP.OutboundAdapter.Post()` builds its own request**; its third
  argument is `pFormVarNames`, not a request object, so a caller-built body is
  discarded. The operations use their own `%Net.HttpRequest`.
* **Claude 5 on Bedrock rejects `temperature`** ("deprecated for this model")
  rather than ignoring it, and model ids need the `us.` inference-profile prefix.
* **Multi-line `if { }` piped into `iris session` does not work** — it is
  evaluated line by line. Setup lives in class methods for this reason.

---

## Licence

This demo is **MIT** licensed — see [LICENSE](../LICENSE). It is sample code: read
it, copy it, change it.

The third-party pieces keep their own terms, and two are worth knowing before you
reuse anything:

| component | terms |
|---|---|
| Synthea, and all data here | Apache 2.0; its output carries no patient-privacy restrictions |
| SapBERT checkpoint | Apache 2.0 (`cambridgeltl/SapBERT-from-PubMedBERT-fulltext`) |
| IRIS for Health Community | InterSystems community-edition terms; not for production use |
| ICD-10-CM | CDC/NCHS, public domain |
| RxNorm | free, NLM, no redistribution restriction |
| SNOMED CT | affiliate licence required to redistribute **descriptions**; UAE has been a member since 2021, which covers use |
| CDT (dental) | **ADA-licensed and redistribution-restricted — do not ship CDT descriptors** |

No terminology content is committed to this repository. The concept table is built
at install time from the codes present in your own FHIR repository, so whatever
licence covers your data covers the index derived from it.

---

## References

1. Mukherjee, S., Shu, J., Mazumder, N., Kernell, T., Wheeler, C., Hastings, S.,
   Sidey-Gibbons, C. *Retrieve, Then Classify: Corpus-Grounded Automation of
   Clinical Value Set Authoring.* arXiv:2604.14616.
   <https://arxiv.org/abs/2604.14616>
   — the 48.6% nonexistent-code figure, and value-set-level F1 of 0.298 for a
   SapBERT cross-encoder against 0.105 zero-shot.
2. *Separating Reasoning from Execution: A Tool-Mediated Agentic Framework for
   NL2SQL and Cohort Construction on OMOP CDM.* ML4H 2026, Proceedings Track.
   — externalised terminology lookup and trace; the 79-of-84 empty-cohort result.
3. Liu, F., Shareghi, E., Meng, Z., Basaldella, M., Collier, N.
   *Self-Alignment Pretraining for Biomedical Entity Representations.*
   NAACL 2021, 4228–4238. arXiv:2010.11784.
   <https://arxiv.org/abs/2010.11784> · <https://github.com/cambridgeltl/sapbert>
   — SapBERT, the encoder behind `Embed.Op`
   (`cambridgeltl/SapBERT-from-PubMedBERT-fulltext`, 109M params, CPU).
4. Malkov, Y. A., Yashunin, D. A. *Efficient and Robust Approximate Nearest
   Neighbor Search Using Hierarchical Navigable Small World Graphs.*
   arXiv:1603.09320. <https://arxiv.org/abs/1603.09320>
   — the index behind `AS HNSW` in IRIS vector search.
5. HL7 FHIR R4 terminology operations:
   [`ValueSet/$expand`](https://hl7.org/fhir/R4/valueset-operation-expand.html) ·
   [`CodeSystem/$subsumes`](https://hl7.org/fhir/R4/codesystem-operation-subsumes.html) ·
   [`CodeSystem/$lookup`](https://hl7.org/fhir/R4/codesystem-operation-lookup.html)
6. [RxNav / RxNorm API](https://lhncbc.nlm.nih.gov/RxNav/APIs/) — brand → ingredient.
7. Walonoski, J., Kramer, M., Nichols, J., Quina, A., Moesel, C., Hall, D.,
   Duffett, C., Dube, K., Gallagher, T., McLachlan, S. *Synthea: An approach,
   method, and software mechanism for generating synthetic patients and the
   synthetic electronic health care record.* Journal of the American Medical
   Informatics Association 2018;25(3):230–238.
   <https://doi.org/10.1093/jamia/ocx079> ·
   <https://github.com/synthetichealth/synthea> (Apache 2.0)
   — the synthetic population used throughout. **No real patient data is
   involved at any point.** Generation parameters and provenance:
   [synthea/README.md](synthea/README.md).
