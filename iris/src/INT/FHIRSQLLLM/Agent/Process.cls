/// The agent: question in, SQL and rows out, with the resolution trail recorded.
///
///   1 EXTRACT    LLM pass -> entities (+ synonyms, specific terms) and dimensions
///   2 CANDIDATES lexical + vector lookup over Terminology.Concept
///   3 EXPAND     $expand is-a, so a concept's descendants come in and its
///                siblings do not
///   4 RERANK     LLM pass sees the WHOLE question plus candidates, and chooses
///   5 SQL        LLM pass, given the real schema and the resolved codes
///   6 GUARD      deterministic SELECT-only check -- a gate, not a prompt
///   7 EXECUTE    read-only, in IRIS
///
/// Every step is an Interoperability message, so Message Viewer is the audit
/// trail with no extra code. The model is never asked to recall a code.
Class INT.FHIRSQLLLM.Agent.Process Extends Ens.BusinessProcess
{

Parameter INVOCATION = "Queue";

/// Config names of the three LLM operations. Separate components so each pass
/// can run a different model and the trace records which answered.
Property ExtractTarget As %String [ InitialExpression = "LLM.Extract" ];

Property RerankTarget As %String [ InitialExpression = "LLM.Rerank" ];

Property SQLTarget As %String [ InitialExpression = "LLM.SQL" ];

/// Embedding and vector search are separate traced components, not inline
/// calls, so Message Viewer shows the full design:
///   extract -> embed -> vector search -> rerank -> SQL -> execute
/// ($expand/$subsumes/RxNav are implemented in Terminology.Client but are not
///  called from here yet; see the README.)
Property EmbedTarget As %String [ InitialExpression = "Embed.Op" ];

Property VectorTarget As %String [ InitialExpression = "Vector.Op" ];

/// SQL schema holding the queryable projection. Defaults to the FHIR server's
/// own search tables, which are real relational tables and mean v1 needs no
/// FHIR SQL Builder projection at all. Point this at a Builder projection when
/// one exists.
Property TableSchema As %String [ InitialExpression = "INT_FHIRSQLLLM_Projection" ];

/// Cap on candidates shown to the rerank pass, so a broad concept cannot
/// overflow the prompt. Diabetes mellitus alone expands to 124 concepts.
Property MaxCandidates As %Integer [ InitialExpression = 120 ];

/// Rows returned to the UI.
Property MaxRows As %Integer [ InitialExpression = 200 ];

Parameter SETTINGS = "ExtractTarget:Agent,RerankTarget:Agent,SQLTarget:Agent,EmbedTarget:Agent,VectorTarget:Agent,TableSchema:Agent,MaxCandidates:Agent,MaxRows:Agent";

Method OnRequest(request As INT.FHIRSQLLLM.Agent.Question, Output response As INT.FHIRSQLLLM.Agent.Answer) As %Status
{
	Set start = $ZHOROLOG
	Set response = ##class(INT.FHIRSQLLLM.Agent.Answer).%New()
	Set response.TurnId = $Select(request.TurnId '= "": request.TurnId, 1: $System.Util.CreateGUID())
	Set models = ""
	Set tSC = $$$OK

	Try {
		// ---------- 1. extract ----------
		Set sc = ..CallLLM(..ExtractTarget, "extract",
			##class(INT.FHIRSQLLLM.Agent.Prompts).Extract(),
			request.Text, 1, response.TurnId, .exText, .m1)
		If $$$ISERR(sc) {
			Set response.Error = "extract pass failed: "_$System.Status.GetErrorText(sc)
		}
		Else {
			Set models = m1
			Set plan = ..ParseJSON(exText, .perr)
			If '$IsObject(plan) {
				Set response.Error = "extract pass returned unparseable JSON: "_perr
			}
			ElseIf plan.answerable = 0 {
				Set response.Answerable = 0
				Set response.Summary = "I cannot answer that from this database."
				If plan."reason_if_not" '= "" Set response.Summary = response.Summary_" "_plan."reason_if_not"
			}
			Else {
				// ---------- 2-4. resolve every concept ----------
				Set resolution = []
				Set allCodes = []
				Set unresolved = ""
				If $IsObject(plan.entities) {
					Set it = plan.entities.%GetIterator()
					While it.%GetNext(.k, .ent) {
						If '$IsObject(ent) Continue
						Set one = ..ResolveEntity(ent, request.Text, response.TurnId, .m2)
						If m2 '= "", models '[ m2 Set models = models_", "_m2
						Do resolution.%Push(one)
						Set kept = 0
						If $IsObject(one.kept) {
							Set it2 = one.kept.%GetIterator()
							While it2.%GetNext(.k2, .c) {
								If $IsObject(c) {
									Do allCodes.%Push(c)
									Set kept = kept + 1
								}
							}
						}
						// A concept that resolved to NOTHING has to stop the turn. It is not
						// enough that other concepts resolved. Asked for "surgery for
						// appendicitis ... Augmentin within 30 days", the SQL pass was handed
						// one resolved condition code and no medication codes at all, and it
						// improvised: it wrote Display LIKE '%Augmentin%' -- against rule 2 of
						// its own prompt -- over a brand name that appears nowhere in the data,
						// and used a procedure code the rerank pass had explicitly DROPPED. A
						// wrong number with a plausible query behind it is the precise failure
						// this design exists to prevent, so the turn abstains and says which
						// concept failed.
						If kept = 0 {
							Set unresolved = unresolved_$Select(unresolved = "": "", 1: ", ")_
								""""_$Select(one.phrase '= "": one.phrase, 1: "(unnamed)")_""""
						}
					}
				}
				Do response.SetResolution(resolution.%ToJSON())

				If allCodes.%Size() = 0 {
					Set response.Answerable = 0
					Set response.Summary = "I could not resolve any clinical concept in that question to codes present in this database."
				}
				ElseIf unresolved '= "" {
					Set response.Answerable = 0
					Set response.Summary = "I resolved part of that question but not all of it. "_unresolved_
						" matched no code present in this database, so I have not run a query -- "_
						"answering anyway would mean guessing which patients those words refer to. "_
						"The resolution trail shows what each concept did and did not match."
				}
				Else {
					// ---------- 5. SQL ----------
					Set userMsg = "Question: "_request.Text_$Char(10,10)_
						"Schema:"_$Char(10)_..SchemaText()_$Char(10)_
						"Resolved codes:"_$Char(10)_..CodesText(resolution)
					Set sc = ..CallLLM(..SQLTarget, "sql",
						##class(INT.FHIRSQLLLM.Agent.Prompts).SQL(),
						userMsg, 1, response.TurnId, .sqlText, .m3)
					If $$$ISERR(sc) {
						Set response.Error = "sql pass failed: "_$System.Status.GetErrorText(sc)
					}
					Else {
						If m3 '= "", models '[ m3 Set models = models_", "_m3
						Set sqlObj = ..ParseJSON(sqlText, .perr2)
						If '$IsObject(sqlObj) {
							Set response.Error = "sql pass returned unparseable JSON: "_perr2
						}
						Else {
							Do ..FinishSQL(sqlObj, request, .response)
						}
					}
				}
			}
		}
	}
	Catch e {
		Set response.Error = "unhandled: "_e.DisplayString()
	}

	Set response.ModelsUsed = models
	Set response.TotalMs = $Normalize(($ZHOROLOG - start) * 1000, 0)
	Quit tSC
}

/// Guard the generated SQL, then execute it unless the caller asked for an
/// explanation only.
Method FinishSQL(sqlObj As %DynamicObject, request As INT.FHIRSQLLLM.Agent.Question, ByRef response As INT.FHIRSQLLLM.Agent.Answer) As %Status
{
	Set sc = ##class(INT.FHIRSQLLLM.Agent.SqlGuard).Check(sqlObj.sql, .clean)
	Do response.SetSQL(clean)
	If $$$ISERR(sc) {
		Set response.Error = "generated SQL rejected by the guard: "_$System.Status.GetErrorText(sc)
		Quit $$$OK
	}
	Set response.Summary = sqlObj.explanation
	If request.ExplainOnly {
		Set response.Summary = response.Summary_" (not executed)"
		Quit $$$OK
	}

	Set rows = []
	Set rs = ##class(%SQL.Statement).%ExecDirect(, clean)
	If rs.%SQLCODE < 0 {
		Set response.Error = "SQL failed: SQLCODE "_rs.%SQLCODE_" "_rs.%Message
		Quit $$$OK
	}
	Set md = rs.%GetMetadata()
	Set n = 0
	While rs.%Next() {
		Set n = n + 1
		If n > ..MaxRows Quit
		Set row = {}
		For c = 1:1:md.columns.Count() {
			Set col = md.columns.GetAt(c).colName
			Do row.%Set(col, rs.%GetData(c))
		}
		Do rows.%Push(row)
	}
	Set response.RowCount = n
	Do response.SetRows(rows.%ToJSON())
	Quit $$$OK
}

/// One concept: lexical candidates, vector candidates, then the rerank pass.
Method ResolveEntity(ent As %DynamicObject, question As %String, turnId As %String, Output pModel As %String) As %DynamicObject
{
	Set pModel = ""
	Set out = {}
	Set out.phrase = ent.phrase
	Set out.domain = ent.domain
	Set out.kept = []
	Set out.dropped = []
	Set out.confidence = "low"

	Set cands = ..Candidates(ent, turnId)
	Set out.candidateCount = cands.%Size()
	If cands.%Size() = 0 {
		Set out.note = "no candidate codes found in this database"
		Quit out
	}

	Set userMsg = "Question: "_question_$Char(10,10)_
		##class(INT.FHIRSQLLLM.Agent.Prompts).FormatCandidates(ent.phrase, ent.domain, cands)
	Set sc = ..CallLLM(..RerankTarget, "rerank",
		##class(INT.FHIRSQLLLM.Agent.Prompts).Rerank(),
		userMsg, 1, turnId, .text, .pModel)
	If $$$ISERR(sc) {
		Set out.note = "rerank failed: "_$System.Status.GetErrorText(sc)
		Quit out
	}
	Set picked = ..ParseJSON(text, .perr)
	If '$IsObject(picked) {
		Set out.note = "rerank returned unparseable JSON: "_perr
		Quit out
	}

	// Only codes that were actually offered may be kept. This is the guard
	// against the failure mode where a model returns codes that do not exist --
	// measured at 48.6% of returned codes in published work.
	Set allowed = ""
	Set it = cands.%GetIterator()
	While it.%GetNext(.k, .c) {
		If $IsObject(c) Set allowed(c.code) = c
	}
	If $IsObject(picked.keep) {
		Set it2 = picked.keep.%GetIterator()
		While it2.%GetNext(.k2, .kc) {
			If '$IsObject(kc) Continue
			If '$Data(allowed(kc.code)) Continue
			Set src = allowed(kc.code)
			Set row = {}
			Set row.code = kc.code
			Set row.system = src.system
			Set row.display = src.display
			Set row.why = kc.why
			Do out.kept.%Push(row)
		}
	}
	If $IsObject(picked.drop) Set out.dropped = picked.drop
	If picked.confidence '= "" Set out.confidence = picked.confidence
	If picked.note '= "" Set out.note = picked.note
	Quit out
}

/// Lexical candidates for a concept, then hierarchy expansion.
///
/// Deliberately NOT scoped by domain: a foreign-domain code cannot survive the
/// join in the generated SQL, so over-retrieval across domains is harmless,
/// while pre-scoping risks missing the concept entirely -- the failure that cost
/// the ML4H paper its worst cohort result.
Method Candidates(ent As %DynamicObject, turnId As %String = "") As %DynamicArray
{
	Set out = []
	Set seen = ""

	// every phrasing the extract pass offered
	Set terms(1) = ent.phrase
	Set i = 1
	For prop = "synonyms", "specific_terms" {
		If $IsObject(ent.%Get(prop)) {
			Set it = ent.%Get(prop).%GetIterator()
			While it.%GetNext(.k, .t) {
				If t '= "" {
					Set i = i + 1
					Set terms(i) = t
				}
			}
		}
	}

	// --- 1. lexical: exact and substring, cheap and precise when it hits
	For j = 1:1:i {
		Set t = terms(j)
		Set rs = ##class(%SQL.Statement).%ExecDirect(,
			"SELECT TOP 40 Code, CodeSystem, Display, SystemLabel, OccurrenceCount "_
			"FROM INT_FHIRSQLLLM_Terminology.Concept "_
			"WHERE DisplayNorm %STARTSWITH ? OR DisplayNorm LIKE ? "_
			"ORDER BY OccurrenceCount DESC",
			$ZConvert(t, "L"), "%"_$ZConvert(t, "L")_"%")
		While rs.%Next() {
			If out.%Size() >= ..MaxCandidates Quit
			Set code = rs.%Get("Code")
			If '$Data(seen(code)) {
				Set seen(code) = 1
				Set row = {}
				Set row.code = code
				Set row.system = rs.%Get("SystemLabel")
				Set row.systemUri = rs.%Get("CodeSystem")
				Set row.display = rs.%Get("Display")
				Set row.occurrences = rs.%Get("OccurrenceCount")
				Set row.via = "lexical"
				Set row.inRepository = 1
				Do out.%Push(row)
			}
		}
	}

	// --- 2. embed the phrase  (traced: Embed.Op)
	Set er = ##class(INT.FHIRSQLLLM.Embed.Request).%New()
	Set er.Purpose = "candidate lookup: "_ent.phrase
	Set er.TurnId = turnId
	Do er.Texts.Insert(ent.phrase)
	Set sc = ..SendRequestSync(..EmbedTarget, er, .ersp)
	If $$$ISOK(sc), $IsObject(ersp), ersp.Vectors.Count() > 0 {
		// --- 3. vector search over the embedded terminology  (traced: Vector.Op)
		Set vr = ##class(INT.FHIRSQLLLM.Vector.Request).%New()
		Set vr.QueryVector = ersp.Vectors.GetAt(1)
		Set vr.Phrase = ent.phrase
		Set vr.TopN = 25
		Set vr.TurnId = turnId
		Set sc2 = ..SendRequestSync(..VectorTarget, vr, .vrsp)
		If $$$ISOK(sc2), $IsObject(vrsp) {
			Set arr = ##class(%DynamicAbstractObject).%FromJSON(vrsp.GetCandidates())
			If $IsObject(arr) {
				Set it3 = arr.%GetIterator()
				While it3.%GetNext(.k3, .c) {
					If $IsObject(c), out.%Size() < ..MaxCandidates {
						If '$Data(seen(c.code)) {
							Set seen(c.code) = 1
							Set c.via = "vector "_c.similarity
							Do out.%Push(c)
						}
					}
				}
			}
		}
	}
	Quit out
}

/// Fire one LLM pass and return its text plus which model answered.
Method CallLLM(target As %String, pass As %String, system As %String, user As %String, expectJSON As %Boolean, turnId As %String, Output pText As %String, Output pModel As %String) As %Status
{
	Set pText = "", pModel = ""
	Set req = ##class(INT.FHIRSQLLLM.LLM.Request).%New()
	Set req.Pass = pass
	// Token budget per pass. The rerank reply carries a keep/drop entry with a
	// reason for EVERY candidate, so 36 candidates overflowed the 2048 default
	// and came back as truncated JSON.
	Set req.MaxTokens = $Case(pass, "rerank": 8192, "sql": 4096, : 2048)
	Set req.ExpectJSON = expectJSON
	Set req.TurnId = turnId
	Do req.SetSystem(system)
	Do req.SetUser(user)
	Set sc = ..SendRequestSync(target, req, .rsp)
	If $$$ISERR(sc) Quit sc
	If '$IsObject(rsp) Quit $$$ERROR($$$GeneralError, "no response from "_target)
	Set pText = rsp.GetText()
	Set pModel = rsp.Model
	Quit $$$OK
}

/// Parse a model reply as JSON, tolerating a stray code fence.
ClassMethod ParseJSON(text As %String, Output pError As %String) As %DynamicObject
{
	Set pError = "", obj = ""
	Set t = $ZStrip(text, "<>WC")
	If t [ "```" {
		Set t = $Replace($Replace($Replace(t, "```json", ""), "```JSON", ""), "```", "")
		Set t = $ZStrip(t, "<>WC")
	}
	Try {
		Set obj = {}.%FromJSON(t)
	}
	Catch e {
		Set pError = e.DisplayString()
		Set obj = ""
	}
	Quit obj
}

/// The real table and column names, read at runtime. FHIR SQL Builder
/// projections are configured per deployment, so nothing here is assumed.
Method SchemaText() As %String
{
	Set s = ""
	Set rs = ##class(%SQL.Statement).%ExecDirect(,
		"SELECT TABLE_NAME, COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS "_
		"WHERE TABLE_SCHEMA = ? "_
		"ORDER BY TABLE_NAME, ORDINAL_POSITION",
		..TableSchema)
	Set last = ""
	While rs.%Next() {
		Set tbl = rs.%Get("TABLE_NAME")
		If tbl '= last {
			If last '= "" Set s = s_$Char(10)
			Set s = s_..TableSchema_"."_tbl_": "
			Set last = tbl
		}
		Else {
			Set s = s_", "
		}
		Set s = s_rs.%Get("COLUMN_NAME")
	}
	If s '= "" {
		Set s = s_$Char(10,10)_
			"One row per (resource, coding). FactType is one of: condition, "_
			"procedure, medication, observation, immunization, allergy. "_
			"Filter on FactType AND Code. Count patients with "_
			"COUNT(DISTINCT PatientId)."_$Char(10)_
			"DATES: FactDate is a STRING (ISO-8601 with offset) -- fine to display, "_
			"fine to compare with <= and >=, but date FUNCTIONS over it return no "_
			"rows. FactDay is the same date as a real date type. Use FactDay for all "_
			"arithmetic and for anything of the form ""within N days"": "_
			"m.FactDay <= DATEADD('day', N, c.FactDay). Use FactDay for year or month "_
			"grouping too."
	}
	Quit s
}

/// Resolved codes, formatted for the SQL pass.
ClassMethod CodesText(resolution As %DynamicArray) As %String
{
	Set s = ""
	Set it = resolution.%GetIterator()
	While it.%GetNext(.k, .r) {
		If '$IsObject(r) Continue
		If '$IsObject(r.kept) Continue
		If r.kept.%Size() = 0 Continue
		Set s = s_"  """_r.phrase_""" ("_r.domain_") = "
		Set it2 = r.kept.%GetIterator()
		Set first = 1
		While it2.%GetNext(.k2, .c) {
			If '$IsObject(c) Continue
			If 'first Set s = s_", "
			Set s = s_"'"_c.code_"'"
			Set first = 0
		}
		Set s = s_$Char(10)
	}
	Quit s
}

Storage Default
{
<Type>%Storage.Persistent</Type>
}

}
