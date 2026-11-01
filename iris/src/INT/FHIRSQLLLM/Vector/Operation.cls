/// Vector search over the embedded terminology, as a traced business operation.
///
/// Runs VECTOR_COSINE against INT_FHIRSQLLLM_Terminology.Concept, which carries
/// an HNSW index. This is the step that finds concepts no substring match can:
/// "gum disease" returns Periodontal disease at 0.772 and "heart attack" returns
/// Myocardial infarction at 0.777, while LIKE on either returns nothing at all.
///
/// It is a candidate generator. Precision comes from $subsumes and the rerank
/// pass, because these vectors rate sibling diseases as highly as true synonyms.
Class INT.FHIRSQLLLM.Vector.Operation Extends Ens.BusinessOperation
{

Parameter INVOCATION = "Queue";

Property ConceptTable As %String(MAXLEN = 128) [ InitialExpression = "INT_FHIRSQLLLM_Terminology.Concept" ];

/// Discard anything below this cosine. 0.45 keeps paraphrases and drops noise;
/// the rerank pass removes near-misses, so be generous here.
Property MinSimilarity As %Numeric [ InitialExpression = 0.45 ];

Parameter SETTINGS = "ConceptTable:Vector,MinSimilarity:Vector";

Method OnMessage(pRequest As INT.FHIRSQLLLM.Vector.Request, Output pResponse As INT.FHIRSQLLLM.Vector.Response) As %Status
{
	Set pResponse = ##class(INT.FHIRSQLLLM.Vector.Response).%New()
	Set start = $ZHOROLOG
	Set out = []

	Try {
		Set dim = $Length(pRequest.QueryVector, ",")
		Set where = "Embedding IS NOT NULL"
		If pRequest.DomainFilter '= "" Set where = where_" AND ConceptDomain = ?"

		Set sql = "SELECT TOP ? Code, CodeSystem, SystemLabel, Display, OccurrenceCount, "_
			"LookupAmbiguous, VECTOR_COSINE(Embedding, TO_VECTOR(?, DOUBLE, "_dim_")) AS Sim "_
			"FROM "_..ConceptTable_" WHERE "_where_" ORDER BY Sim DESC"

		If pRequest.DomainFilter '= "" {
			Set rs = ##class(%SQL.Statement).%ExecDirect(, sql, pRequest.TopN, pRequest.QueryVector, pRequest.DomainFilter)
		}
		Else {
			Set rs = ##class(%SQL.Statement).%ExecDirect(, sql, pRequest.TopN, pRequest.QueryVector)
		}

		If rs.%SQLCODE < 0 {
			Set pResponse.Error = "SQLCODE "_rs.%SQLCODE_" "_rs.%Message
		}
		Else {
			Set top = ""
			While rs.%Next() {
				Set sim = rs.%Get("Sim")
				If sim < ..MinSimilarity Quit
				If top = "" Set top = sim
				Set row = {}
				Set row.code = rs.%Get("Code")
				Set row.system = rs.%Get("SystemLabel")
				Set row.systemUri = rs.%Get("CodeSystem")
				Set row.display = rs.%Get("Display")
				Set row.occurrences = rs.%Get("OccurrenceCount")
				Set row.ambiguous = rs.%Get("LookupAmbiguous")
				Set row.similarity = $FNumber(sim, "", 4)
				Set row.inRepository = 1
				Do out.%Push(row)
			}
			Set pResponse.TopSimilarity = $Select(top '= "": top, 1: 0)
		}
	}
	Catch e {
		Set pResponse.Error = e.DisplayString()
	}

	Set pResponse.Count = out.%Size()
	Do pResponse.SetCandidates(out.%ToJSON())
	Set pResponse.LatencyMs = $Normalize(($ZHOROLOG - start) * 1000, 0)
	Quit $$$OK
}

}
