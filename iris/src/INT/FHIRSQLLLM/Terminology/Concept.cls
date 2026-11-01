/// The terminology index the agent resolves against.
///
/// An embedding model such as SapBERT contains no codes -- it is a text encoder.
/// Resolution needs a stored table of (code, system, display) that can be
/// searched, which is this class. v1 searches it lexically; v2 adds vector
/// search over the Embedding column, which is nullable so v1 needs no embedding
/// model at all.
///
/// Populated from the deployment's own FHIR data, so every code the agent
/// resolves is guaranteed to exist in the repository and be queryable.
Class INT.FHIRSQLLLM.Terminology.Concept Extends %Persistent [ DdlAllowed ]
{

Property Code As %String(MAXLEN = 64) [ Required ];

/// Full system URI, e.g. http://snomed.info/sct
Property CodeSystem As %String(MAXLEN = 255) [ Required ];

Property Display As %String(MAXLEN = 512);

/// Which projection / fact table this concept is used in:
/// condition | procedure | medication | observation | immunization | allergy
/// SQL field is ConceptDomain because DOMAIN is a RESERVED WORD in IRIS SQL --
/// an unquoted "SELECT Domain" fails with SQLCODE -12, silently returning no
/// rows rather than erroring loudly.
Property Domain As %String(MAXLEN = 64) [ SqlFieldName = ConceptDomain ];

/// Lowercased Display, for case-insensitive lexical matching without
/// forcing a scan through UPPER() on every row.
Property DisplayNorm As %String(MAXLEN = 512);

/// Short system label for prompts, e.g. SNOMED / ICD-10-CM / RxNorm / LOINC.
/// LLM passes read this; the full URI is noise in a prompt.
Property SystemLabel As %String(MAXLEN = 32);

/// How many rows in the repository carry this code. Used to break ties and to
/// tell the rerank pass which codes actually have data behind them.
Property OccurrenceCount As %Integer [ InitialExpression = 0 ];

/// True when this Display is a substring of another Display in the same domain,
/// i.e. a naive LIKE search on it would pull in other concepts. Precomputed
/// because it is the single best signal that a lexical match is unsafe.
Property LookupAmbiguous As %Boolean [ InitialExpression = 0 ];

/// v2 only. Nullable: v1 leaves it empty and searches lexically.
/// If this property fails to compile on your IRIS version, drop it and add the
/// column with DDL instead:
///   ALTER TABLE INT_FHIRSQLLLM_Terminology.Concept ADD Embedding VECTOR(DOUBLE, 768)
Property Embedding As %Vector(DATATYPE = "DOUBLE", LEN = 768);

Index idxUnique On (CodeSystem, Code, Domain) [ Unique ];

Index idxDomain On Domain;

Index idxDisplayNorm On DisplayNorm;

/// NOTE: the HNSW vector index is NOT declared here. Index parameters
/// (Distance=Cosine) are not expressible in UDL, so it has to be created by DDL
/// -- and a DDL-created index is DESTROYED by the next class recompile, because
/// this .cls source is the source of truth. Re-run
/// INT.FHIRSQLLLM.Terminology.Loader.CreateVectorIndex() after any recompile.




/// Map a system URI to the short label an LLM prompt should see.
ClassMethod LabelFor(uri As %String) As %String
{
	If uri [ "snomed" Quit "SNOMED"
	If uri [ "icd-10-cm" Quit "ICD-10-CM"
	If uri [ "icd-10" Quit "ICD-10"
	If uri [ "icd-9" Quit "ICD-9-CM"
	If uri [ "rxnorm" Quit "RxNorm"
	If uri [ "loinc" Quit "LOINC"
	If uri [ "/cvx" Quit "CVX"
	If uri [ "ada.org/cdt" Quit "CDT"
	If uri [ "unitsofmeasure" Quit "UCUM"
	Quit $Piece(uri, "/", *)
}

/// Add or update one concept.
ClassMethod Upsert(code As %String, system As %String, display As %String, domain As %String, count As %Integer = 0) As %Status
{
	Set id = ..idxUniqueOpen(system, code, domain, , .sc)
	If '$IsObject(id) {
		Set id = ..%New()
		Set id.Code = code
		Set id.CodeSystem = system
	}
	// Domain is set on every call, not only on create. It was previously inside
	// the create branch, which left it null on rows that already existed.
	Set id.Domain = $Select(domain '= "": domain, 1: "unknown")
	Set id.Display = display
	Set id.DisplayNorm = $ZConvert(display, "L")
	Set id.SystemLabel = ..LabelFor(system)
	Set id.OccurrenceCount = count
	Quit id.%Save()
}

/// Populate from the deployment's FHIR SQL Builder projections.
///
/// The projection schema is chosen per deployment by the data steward, so the
/// source tables are passed in rather than assumed. Each spec is a $ListBuild of
///     (domain, tableName, codeColumn, systemColumn, displayColumn)
///
/// Example:
///   set specs = $lb(
///     $lb("condition","SQLUser.Condition","code","codeSystem","codeDisplay"),
///     $lb("procedure","SQLUser.Procedure","code","codeSystem","codeDisplay"))
///   do ##class(INT.FHIRSQLLLM.Terminology.Concept).PopulateFromProjections(specs)
ClassMethod PopulateFromProjections(specs As %List, verbose As %Boolean = 1) As %Status
{
	Set tSC = $$$OK, total = 0
	For i = 1:1:$ListLength(specs) {
		Set spec = $List(specs, i)
		Set domain  = $List(spec, 1)
		Set table   = $List(spec, 2)
		Set colCode = $List(spec, 3)
		Set colSys  = $List(spec, 4)
		Set colDisp = $List(spec, 5)

		Set sql = "SELECT "_colCode_" AS Code, "_colSys_" AS Sys, "
			_"MAX("_colDisp_") AS Disp, COUNT(*) AS N "
			_"FROM "_table_" "
			_"WHERE "_colCode_" IS NOT NULL AND "_colSys_" IS NOT NULL "
			_"GROUP BY "_colCode_", "_colSys

		Set rs = ##class(%SQL.Statement).%ExecDirect(, sql)
		If rs.%SQLCODE < 0 {
			If verbose Write "  !! ", table, ": SQLCODE ", rs.%SQLCODE, " ", rs.%Message, !
			Continue
		}
		Set n = 0
		While rs.%Next() {
			Set sc = ..Upsert(rs.Code, rs.Sys, rs.Disp, domain, rs.N)
			If $$$ISERR(sc) Set tSC = sc
			Set n = n + 1
		}
		Set total = total + n
		If verbose Write "  ", domain, ": ", n, " concepts from ", table, !
	}
	If verbose Write "total: ", total, " concepts", !
	If total > 0 Do ..FlagAmbiguous(verbose)
	Quit tSC
}

/// Precompute LookupAmbiguous: a Display whose text is contained in a longer
/// Display in the same domain. Those are exactly the concepts where a naive
/// LIKE '%term%' lookup silently pulls in other diseases -- on a Synthea
/// extract, '%periodontitis%' returned 36 concepts including Aggressive and
/// Acute apical periodontitis, inflating a patient count 3,248 -> 3,672.
ClassMethod FlagAmbiguous(verbose As %Boolean = 1) As %Status
{
	// Done in ObjectScript rather than one correlated UPDATE: the SQL version
	// aliased the UPDATE target, which IRIS did not honour, and it silently
	// flagged nothing. With a few thousand concepts the loop is trivial and,
	// more importantly, verifiable.
	&sql(UPDATE INT_FHIRSQLLLM_Terminology.Concept SET LookupAmbiguous = 0)

	Kill d
	Set rs = ##class(%SQL.Statement).%ExecDirect(,
		"SELECT ID, ConceptDomain, DisplayNorm FROM INT_FHIRSQLLLM_Terminology.Concept "_
		"WHERE DisplayNorm IS NOT NULL")
	While rs.%Next() {
		Set dom = rs.%Get("ConceptDomain")
		Set txt = rs.%Get("DisplayNorm")
		If txt = "" Continue
		If dom = "" Set dom = "unknown"
		Set d(dom, rs.%Get("ID")) = txt
	}

	Set flagged = 0, dom = ""
	For {
		Set dom = $Order(d(dom))
		Quit:dom=""
		// a display is ambiguous when some LONGER display in the same domain
		// contains it -- i.e. LIKE '%text%' would pull in that other concept too
		Set id = ""
		For {
			Set id = $Order(d(dom, id))
			Quit:id=""
			Set me = d(dom, id)
			Set other = "", hit = 0
			For {
				Set other = $Order(d(dom, other))
				Quit:other=""
				If other = id Continue
				Set cand = d(dom, other)
				If $Length(cand) '> $Length(me) Continue
				If cand [ me {
					Set hit = 1
					Quit
				}
			}
			If hit {
				&sql(UPDATE INT_FHIRSQLLLM_Terminology.Concept
					SET LookupAmbiguous = 1 WHERE ID = :id)
				Set flagged = flagged + 1
			}
		}
	}
	If verbose Write "  flagged ambiguous: ", flagged, !
	Quit $$$OK
}

Storage Default
{
<Data name="ConceptDefaultData">
<Value name="1">
<Value>%%CLASSNAME</Value>
</Value>
<Value name="2">
<Value>Code</Value>
</Value>
<Value name="3">
<Value>CodeSystem</Value>
</Value>
<Value name="4">
<Value>Display</Value>
</Value>
<Value name="5">
<Value>Domain</Value>
</Value>
<Value name="6">
<Value>DisplayNorm</Value>
</Value>
<Value name="7">
<Value>SystemLabel</Value>
</Value>
<Value name="8">
<Value>OccurrenceCount</Value>
</Value>
<Value name="9">
<Value>LookupAmbiguous</Value>
</Value>
<Value name="10">
<Value>Embedding</Value>
</Value>
</Data>
<DataLocation>^INT.FHIRSQLLLM.TerminologyD</DataLocation>
<DefaultData>ConceptDefaultData</DefaultData>
<IdLocation>^INT.FHIRSQLLLM.TerminologyD</IdLocation>
<IndexLocation>^INT.FHIRSQLLLM.TerminologyI</IndexLocation>
<StreamLocation>^INT.FHIRSQLLLM.TerminologyS</StreamLocation>
<Type>%Storage.Persistent</Type>
}

}
