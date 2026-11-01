/// Builds Terminology.Concept from the deployment's own FHIR resources.
///
/// Why not read the FHIR search tables: their token columns are $LIST-encoded
/// (code, "system|code", "system|") and carry NO display text. Displays live
/// only in the resource JSON, so that is what we parse.
///
/// Building from the repository rather than from a terminology download means
/// every code the agent can resolve is guaranteed to exist in the data and be
/// queryable -- no resolving to a code that returns nothing.
Class INT.FHIRSQLLLM.Terminology.Loader
{

/// Which element holds the clinical code, per resource type. Everything else in
/// a resource (category, clinicalStatus, verificationStatus) is NOT terminology
/// and must stay out -- "Encounter Diagnosis" is the top Condition *category*
/// value with 10,973 rows and would otherwise swamp the table.
ClassMethod CodePath(resourceType As %String) As %String
{
	If resourceType = "Condition" Quit "code"
	If resourceType = "Procedure" Quit "code"
	If resourceType = "Observation" Quit "code"
	If resourceType = "AllergyIntolerance" Quit "code"
	If resourceType = "MedicationRequest" Quit "medicationCodeableConcept"
	If resourceType = "Immunization" Quit "vaccineCode"
	Quit ""
}

/// Domain label used by the agent, per resource type.
ClassMethod Domain(resourceType As %String) As %String
{
	If resourceType = "MedicationRequest" Quit "medication"
	If resourceType = "AllergyIntolerance" Quit "allergy"
	Quit $ZConvert($Extract(resourceType), "L")_$Extract(resourceType, 2, *)
}

/// Scan the repository and upsert every clinical code found.
ClassMethod Run(verbose As %Boolean = 1) As %Status
{
	Set types = $ListBuild("Condition", "Procedure", "MedicationRequest",
		"Observation", "Immunization", "AllergyIntolerance")
	Set grand = 0
	For i = 1:1:$ListLength(types) {
		Set rt = $List(types, i)
		Set path = ..CodePath(rt)
		If path = "" Continue
		Set domain = ..Domain(rt)
		Set n = ..RunOne(rt, path, domain, verbose)
		Set grand = grand + n
		If verbose Write "  ", rt, ": ", n, " distinct concepts", !
	}
	If verbose Write "total distinct concepts: ", grand, !
	If grand > 0 {
		If verbose Write "flagging lexically ambiguous displays ...", !
		Do ##class(INT.FHIRSQLLLM.Terminology.Concept).FlagAmbiguous(verbose)
	}
	Quit $$$OK
}

/// One resource type. Counts occurrences so the rerank pass can be told which
/// codes actually have data behind them.
ClassMethod RunOne(resourceType As %String, path As %String, domain As %String, verbose As %Boolean = 1) As %Integer
{
	Kill found
	Set rs = ##class(%SQL.Statement).%ExecDirect(,
		"SELECT ResourceString, ResourceStream FROM HSFHIR_X0001_R.Rsrc "_
		"WHERE ResourceType = ? AND Deleted = 0", resourceType)
	If rs.%SQLCODE < 0 {
		If verbose Write "  !! ", resourceType, ": SQLCODE ", rs.%SQLCODE, " ", rs.%Message, !
		Quit 0
	}

	Set rows = 0
	While rs.%Next() {
		Set rows = rows + 1
		Set json = rs.%Get("ResourceString")
		If json = "" {
			Set stream = rs.%Get("ResourceStream")
			If $IsObject(stream) {
				Do stream.Rewind()
				Set json = stream.Read(stream.Size)
			}
		}
		If json = "" Continue

		Try {
			Set obj = {}.%FromJSON(json)
		}
		Catch {
			Continue
		}
		If '$IsObject(obj) Continue
		Set cc = obj.%Get(path)
		If '$IsObject(cc) Continue
		If '$IsObject(cc.coding) Continue

		Set it = cc.coding.%GetIterator()
		While it.%GetNext(.k, .c) {
			If '$IsObject(c) Continue
			If c.code = "" Continue
			If c.system = "" Continue
			Set key = c.system_$Char(1)_c.code
			Set found(key) = $Get(found(key)) + 1
			If '$Data(disp(key)), c.display '= "" Set disp(key) = c.display
		}
	}

	// upsert
	Set n = 0, key = ""
	For {
		Set key = $Order(found(key))
		Quit:key=""
		Set system = $Piece(key, $Char(1), 1)
		Set code = $Piece(key, $Char(1), 2)
		Set display = $Get(disp(key))
		If display = "" Set display = code
		Set sc = ##class(INT.FHIRSQLLLM.Terminology.Concept).Upsert(
			code, system, display, domain, found(key))
		If $$$ISOK(sc) Set n = n + 1
	}
	Quit n
}

/// Sidecar base URL. Embeddings run outside the IRIS process: Embedded Python
/// cannot see a venv, and a 110M-parameter model should not share the database
/// process.
Parameter SIDECAR = "http://127.0.0.1:8088";

/// Populate the Embedding column by calling the sidecar's SapBERT endpoint.
///
/// Caveat worth keeping in mind when reading any vector-search result here:
/// SapBERT rates "Chronic periodontitis" against "Aggressive periodontitis" at
/// cosine 0.790, HIGHER than "heart attack" against "myocardial infarction" at
/// 0.778. Embeddings give recall, not precision on siblings. Vector search is a
/// candidate generator; $subsumes and the rerank pass decide.
ClassMethod EmbedAll(batchSize As %Integer = 32, verbose As %Boolean = 1) As %Status
{
	Set done = 0, failed = 0
	For {
		// one batch of not-yet-embedded concepts
		Set rs = ##class(%SQL.Statement).%ExecDirect(,
			"SELECT TOP ? ID, Display FROM INT_FHIRSQLLLM_Terminology.Concept "_
			"WHERE Embedding IS NULL AND Display IS NOT NULL", batchSize)
		Set texts = [], n = 0
		Kill ids
		While rs.%Next() {
			Set n = n + 1
			Set ids(n) = rs.%Get("ID")
			Do texts.%Push(rs.%Get("Display"))
		}
		If n = 0 Quit

		Set payload = {}
		Set payload.texts = texts
		Set vecs = ..PostSidecar("/embed", payload, .err)
		If '$IsObject(vecs) {
			If verbose Write "  embed failed: ", err, !
			Set failed = failed + n
			Quit
		}
		Set arr = vecs.vectors
		If '$IsObject(arr) {
			If verbose Write "  no vectors in reply", !
			Quit
		}

		For j = 1:1:n {
			Set v = arr.%Get(j - 1)
			If '$IsObject(v) Continue
			// TO_VECTOR wants a comma-separated string
			Set csv = ""
			Set it = v.%GetIterator()
			While it.%GetNext(.k, .f) {
				Set csv = csv_$Select(csv = "": "", 1: ",")_f
			}
			Set id = ids(j)
			&sql(UPDATE INT_FHIRSQLLLM_Terminology.Concept
				SET Embedding = TO_VECTOR(:csv, DOUBLE, 768) WHERE ID = :id)
			If SQLCODE = 0 { Set done = done + 1 } Else { Set failed = failed + 1 }
		}
		If verbose, (done # 128) < batchSize Write "  embedded ", done, " ...", !
	}
	If verbose Write "embedded ", done, ", failed ", failed, !
	Quit $$$OK
}

/// Create the HNSW index so VECTOR_COSINE search is indexed rather than a scan.
ClassMethod CreateVectorIndex() As %Status
{
	// idempotent: a recompile of the class destroys the index, and re-creating
	// over an existing one errors, so drop first and ignore the failure
	Do ##class(%SQL.Statement).%ExecDirect(,
		"DROP INDEX idxEmbedding ON TABLE INT_FHIRSQLLLM_Terminology.Concept")
	Set sql = "CREATE INDEX idxEmbedding ON TABLE INT_FHIRSQLLLM_Terminology.Concept "_
		"(Embedding) AS HNSW(Distance='Cosine')"
	Set rs = ##class(%SQL.Statement).%ExecDirect(, sql)
	Write "HNSW index: ", $Select(rs.%SQLCODE = 0: "created", 1: "SQLCODE "_rs.%SQLCODE_" "_rs.%Message), !
	Set chk = ##class(%SQL.Statement).%ExecDirect(,
		"SELECT COUNT(*) AS N FROM INFORMATION_SCHEMA.INDEXES "_
		"WHERE TABLE_SCHEMA='INT_FHIRSQLLLM_Terminology' AND TABLE_NAME='Concept' "_
		"AND INDEX_NAME='idxEmbedding'")
	If chk.%Next() Write "  present in INFORMATION_SCHEMA: ", chk.%Get("N"), !
	Quit $$$OK
}

/// Nearest concepts to a free-text phrase, by cosine over the stored vectors.
ClassMethod VectorSearch(phrase As %String, top As %Integer = 8) As %Status
{
	Set payload = {}
	Set payload.texts = [].%Push(phrase)
	Set out = ..PostSidecar("/embed", payload, .err)
	If '$IsObject(out) {
		Write "embed failed: ", err, !
		Quit $$$OK
	}
	Set v = out.vectors.%Get(0)
	Set csv = ""
	Set it = v.%GetIterator()
	While it.%GetNext(.k, .f) {
		Set csv = csv_$Select(csv = "": "", 1: ",")_f
	}

	Write !, "=== nearest concepts to '", phrase, "' ===", !
	Set rs = ##class(%SQL.Statement).%ExecDirect(,
		"SELECT TOP ? Code, Display, SystemLabel, "_
		"VECTOR_COSINE(Embedding, TO_VECTOR(?, DOUBLE, 768)) AS Sim "_
		"FROM INT_FHIRSQLLLM_Terminology.Concept "_
		"WHERE Embedding IS NOT NULL ORDER BY Sim DESC", top, csv)
	If rs.%SQLCODE < 0 {
		Write "  SQLCODE ", rs.%SQLCODE, " ", rs.%Message, !
		Quit $$$OK
	}
	While rs.%Next() {
		Write "  ", $Justify($FNumber(rs.%Get("Sim"), "", 3), 7), "  ",
			$Justify(rs.%Get("Code"), 14), "  ", rs.%Get("Display"), !
	}
	Quit $$$OK
}

/// POST JSON to the sidecar.
ClassMethod PostSidecar(path As %String, body As %DynamicObject, Output pError As %String) As %DynamicObject
{
	Set pError = "", result = ""
	Try {
		Set req = ##class(%Net.HttpRequest).%New()
		Set req.Server = "127.0.0.1"
		Set req.Port = 8088
		Set req.Timeout = 300
		Set req.ContentType = "application/json"
		Do req.EntityBody.Write(body.%ToJSON())
		Set sc = req.Post(path)
		If $$$ISERR(sc) {
			Set pError = $System.Status.GetErrorText(sc)
		}
		ElseIf (req.HttpResponse.StatusCode < 200) || (req.HttpResponse.StatusCode > 299) {
			Do req.HttpResponse.Data.Rewind()
			Set pError = "HTTP "_req.HttpResponse.StatusCode_" "_req.HttpResponse.Data.Read(300)
		}
		Else {
			Do req.HttpResponse.Data.Rewind()
			Set result = {}.%FromJSON(req.HttpResponse.Data)
		}
	}
	Catch e {
		Set pError = e.DisplayString()
		Set result = ""
	}
	Quit result
}

/// What the table ended up holding. Also the numbers for the write-up.
ClassMethod Report() As %Status
{
	Write !, "=== Terminology.Concept ===", !
	Set rs = ##class(%SQL.Statement).%ExecDirect(,
		"SELECT ConceptDomain, SystemLabel, COUNT(*) AS N, SUM(OccurrenceCount) AS Rows_, "_
		"SUM(CASE WHEN LookupAmbiguous = 1 THEN 1 ELSE 0 END) AS Amb "_
		"FROM INT_FHIRSQLLLM_Terminology.Concept "_
		"GROUP BY ConceptDomain, SystemLabel ORDER BY ConceptDomain, 3 DESC")
	While rs.%Next() {
		Write "  ", $Justify(rs.%Get("N"), 6), " concepts  ",
			$Justify(rs.%Get("Amb"), 4), " ambiguous  ",
			$Justify(rs.%Get("Rows_"), 8), " rows   ",
			rs.%Get("ConceptDomain"), " / ", rs.%Get("SystemLabel"), !
	}
	Set r2 = ##class(%SQL.Statement).%ExecDirect(,
		"SELECT COUNT(*) AS N, SUM(CASE WHEN LookupAmbiguous=1 THEN 1 ELSE 0 END) AS A "_
		"FROM INT_FHIRSQLLLM_Terminology.Concept")
	While r2.%Next() {
		Set n = r2.%Get("N"), a = r2.%Get("A")
		Write !, "  TOTAL ", n, " concepts, ", a, " lexically ambiguous"
		If n > 0 Write " (", $Normalize(100 * a / n, 1), "%)"
		Write !
	}
	Quit $$$OK
}

/// The demo's sharpest 30 seconds: take every concept a naive LIKE search
/// returns, and ask SNOMED whether it actually belongs.
///
/// The count comparison is not the story -- on a small extract LIKE and $expand
/// return similar numbers. What matters is COMPOSITION: LIKE returns different
/// diseases that happen to share a word, and those silently change the patient
/// population. This method names them and counts the rows they would add.
ClassMethod JudgeLexicalHits(term As %String = "periodontitis", anchor As %String = "5689008", system As %String = "http://snomed.info/sct") As %Status
{
	Write !, "=== LIKE '%", term, "%' judged by SNOMED subsumption of ", anchor, " ===", !
	Set keep = 0, drop = 0, keepRows = 0, dropRows = 0
	Set rs = ##class(%SQL.Statement).%ExecDirect(,
		"SELECT Code, Display, OccurrenceCount FROM INT_FHIRSQLLLM_Terminology.Concept "_
		"WHERE DisplayNorm LIKE ? AND CodeSystem = ? ORDER BY Display",
		"%"_$ZConvert(term, "L")_"%", system)
	While rs.%Next() {
		Set code = rs.%Get("Code")
		Set disp = rs.%Get("Display")
		Set n = +rs.%Get("OccurrenceCount")
		Set verdict = ##class(INT.FHIRSQLLLM.Terminology.Client).Subsumes(anchor, code, system, .err)
		If verdict = "" Set verdict = "ERR:"_err
		Set belongs = ((verdict = "subsumes") || (verdict = "equivalent"))
		If belongs {
			Set keep = keep + 1, keepRows = keepRows + n
		}
		Else {
			Set drop = drop + 1, dropRows = dropRows + n
		}
		Write "  ", $Select(belongs: "KEEP  ", 1: "DROP  "),
			$Justify(code, 14), "  ", $Extract(disp, 1, 44),
			"   [", verdict, "]  ", n, " rows", !
	}
	Write !, "  LIKE returned ", keep + drop, " concepts: ", keep, " belong, ", drop, " do NOT", !
	Write "  rows a LIKE query would wrongly include: ", dropRows,
		" of ", keepRows + dropRows, !
	If (keepRows + dropRows) > 0 {
		Write "  i.e. ", $Normalize(100 * dropRows / (keepRows + dropRows), 1),
			"% of the matched rows are a different disease", !
	}
	Quit $$$OK
}

/// The demo's headline comparison, computed live rather than quoted.
///
/// Naive substring matching vs the real hierarchy, on whatever concept you name.
ClassMethod CompareLexicalVsHierarchy(term As %String = "periodontitis", anchor As %String = "5689008") As %Status
{
	Write !, "=== '", term, "' : naive LIKE vs SNOMED hierarchy ===", !

	Set rs = ##class(%SQL.Statement).%ExecDirect(,
		"SELECT COUNT(*) AS N FROM INT_FHIRSQLLLM_Terminology.Concept "_
		"WHERE DisplayNorm LIKE ?", "%"_$ZConvert(term, "L")_"%")
	While rs.%Next() { Set lex = rs.%Get("N") }
	Write "  LIKE '%", term, "%'            -> ", $Get(lex, 0), " concepts", !

	Set arr = ##class(INT.FHIRSQLLLM.Terminology.Client).Expand(anchor, , 500, .err, .total)
	If err '= "" {
		Write "  $expand is-a ", anchor, "        -> ERROR ", err, !
	}
	Else {
		Write "  $expand is-a ", anchor, "        -> ", total, " concepts (the true subtree)", !
	}

	Write !, "  the difference is other diseases that share a word:", !
	Set r2 = ##class(%SQL.Statement).%ExecDirect(,
		"SELECT TOP 8 Code, Display FROM INT_FHIRSQLLLM_Terminology.Concept "_
		"WHERE DisplayNorm LIKE ? ORDER BY Display", "%"_$ZConvert(term, "L")_"%")
	While r2.%Next() {
		Write "     ", $Justify(r2.%Get("Code"), 16), "  ", r2.%Get("Display"), !
	}
	Quit $$$OK
}

}
