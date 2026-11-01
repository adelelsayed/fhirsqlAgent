/// Deterministic terminology resolution over free public services.
///
/// Nothing here is a model. Every method is a lookup against a published
/// hierarchy or relationship graph, so results are reproducible and auditable --
/// which is the whole point of resolving terminology outside the LLM.
///
/// Verified working against these endpoints:
///   tx.fhir.org  $expand  is-a 5689008  -> 13 concepts, correctly EXCLUDING the
///                                          aggressive-periodontitis subtree
///                $subsumes              -> chronic vs generalised  = subsumes
///                                          chronic vs aggressive   = not-subsumed
///   rxnav        Augmentin -> rxcui 151392 -> amoxicillin + clavulanate -> 7 SCDs
///
/// Contrast with a naive LIKE: '%periodontitis%' returns 36 concepts including
/// two different diseases, which inflated a Synthea patient count 3,248 -> 3,672.
Class INT.FHIRSQLLLM.Terminology.Client Extends %RegisteredObject
{

/// Public HL7 terminology server. No key, no account.
Parameter TXSERVER = "https://tx.fhir.org/r4";

Parameter RXNAV = "https://rxnav.nlm.nih.gov";

/// IRIS SSL/TLS configuration name. Client-only, no certificate files needed.
Parameter SSLCONFIG = "LLMClient";

Parameter SNOMED = "http://snomed.info/sct";

/// Seconds.
Parameter TIMEOUT = 60;

/// Shared HTTP GET returning a parsed JSON object, or "" on failure with the
/// reason in pError.
ClassMethod GetJSON(url As %String, Output pError As %String) As %DynamicObject
{
	Set pError = "", result = ""
	Try {
		Set req = ##class(%Net.HttpRequest).%New()
		Set req.SSLConfiguration = ..#SSLCONFIG
		Set req.Timeout = ..#TIMEOUT
		Do req.SetHeader("accept", "application/json")
		Set sc = req.Get(url)
		If $$$ISERR(sc) {
			Set pError = $System.Status.GetErrorText(sc)
		}
		ElseIf (req.HttpResponse.StatusCode < 200) || (req.HttpResponse.StatusCode > 299) {
			Set pError = "HTTP "_req.HttpResponse.StatusCode
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

/// POST a FHIR Parameters resource and return the parsed response.
ClassMethod PostFHIR(path As %String, body As %DynamicObject, Output pError As %String) As %DynamicObject
{
	Set pError = "", result = ""
	Try {
		Set req = ##class(%Net.HttpRequest).%New()
		Set req.SSLConfiguration = ..#SSLCONFIG
		Set req.Timeout = ..#TIMEOUT
		Set req.ContentType = "application/fhir+json"
		Do req.SetHeader("accept", "application/fhir+json")
		Do req.EntityBody.Write(body.%ToJSON())
		Set sc = req.Post(..#TXSERVER_path)
		If $$$ISERR(sc) {
			Set pError = $System.Status.GetErrorText(sc)
		}
		ElseIf (req.HttpResponse.StatusCode < 200) || (req.HttpResponse.StatusCode > 299) {
			Do req.HttpResponse.Data.Rewind()
			Set pError = "HTTP "_req.HttpResponse.StatusCode_" "_req.HttpResponse.Data.Read(500)
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

/// A concept and all its descendants, via ValueSet/$expand with an is-a filter.
///
/// This is the operation that makes hierarchy-aware resolution possible: it
/// returns the subtree and NOTHING ELSE, so sibling diseases stay out.
/// Returns a %DynamicArray of {code, display}; check pError on empty.
ClassMethod Expand(code As %String, system As %String = {..#SNOMED}, max As %Integer = 500, Output pError As %String, Output pTotal As %Integer) As %DynamicArray
{
	Set pError = "", pTotal = 0, out = []
	Set vs = {"resourceType":"ValueSet"}
	Set vs.compose = {}
	Set inc = {}
	Set inc.system = system
	Set inc.filter = [].%Push({"property":"concept","op":"is-a"})
	Do inc.filter.%Get(0).%Set("value", code)
	Set vs.compose.include = [].%Push(inc)

	Set params = {"resourceType":"Parameters"}
	Set params.parameter = []
	Set p1 = {"name":"valueSet"}
	Set p1.resource = vs
	Do params.parameter.%Push(p1)
	Set p2 = {"name":"count"}
	Set p2."valueInteger" = max
	Do params.parameter.%Push(p2)

	Set resp = ..PostFHIR("/ValueSet/$expand", params, .pError)
	If '$IsObject(resp) Quit out
	If '$IsObject(resp.expansion) {
		Set pError = "no expansion in response"
		Quit out
	}
	Set pTotal = +resp.expansion.total
	If $IsObject(resp.expansion.contains) {
		Set it = resp.expansion.contains.%GetIterator()
		While it.%GetNext(.k, .c) {
			If '$IsObject(c) Continue
			Set row = {}
			Set row.code = c.code
			Set row.display = c.display
			Do out.%Push(row)
		}
	}
	Quit out
}

/// Does codeA subsume codeB? Returns: subsumes | subsumed-by | equivalent |
/// not-subsumed | "" on error.
///
/// This is the test that separates a concept's descendants from its siblings.
/// Verified: 5689008 (chronic periodontitis) vs 715859008 (localised moderate
/// AGGRESSIVE periodontitis) -> not-subsumed, which is exactly the
/// discrimination `LIKE '%periodontitis%'` cannot make.
ClassMethod Subsumes(codeA As %String, codeB As %String, system As %String = {..#SNOMED}, Output pError As %String) As %String
{
	Set pError = ""
	Set url = ..#TXSERVER_"/CodeSystem/$subsumes"_
		"?system="_$ZConvert(system, "O", "URL")_
		"&codeA="_$ZConvert(codeA, "O", "URL")_
		"&codeB="_$ZConvert(codeB, "O", "URL")
	Set resp = ..GetJSON(url, .pError)
	If '$IsObject(resp) Quit ""
	Set outcome = ""
	If $IsObject(resp.parameter) {
		Set it = resp.parameter.%GetIterator()
		While it.%GetNext(.k, .p) {
			If $IsObject(p), p.name = "outcome" {
				Set outcome = p."valueCode"
				Quit
			}
		}
	}
	If outcome = "" Set pError = "no outcome parameter"
	Quit outcome
}

/// Look up a code's display and properties.
ClassMethod Lookup(code As %String, system As %String = {..#SNOMED}, Output pError As %String) As %String
{
	Set pError = ""
	Set url = ..#TXSERVER_"/CodeSystem/$lookup"_
		"?system="_$ZConvert(system, "O", "URL")_
		"&code="_$ZConvert(code, "O", "URL")
	Set resp = ..GetJSON(url, .pError)
	If '$IsObject(resp) Quit ""
	Set display = ""
	If $IsObject(resp.parameter) {
		Set it = resp.parameter.%GetIterator()
		While it.%GetNext(.k, .p) {
			If $IsObject(p), p.name = "display" {
				Set display = p."valueString"
				Quit
			}
		}
	}
	Quit display
}

/// Brand or ingredient name -> RxNorm concept id. Free, no key.
/// "Augmentin" -> 151392
ClassMethod RxNormIdByName(name As %String, Output pError As %String) As %String
{
	Set pError = ""
	Set url = ..#RXNAV_"/REST/rxcui.json?search=2&name="_$ZConvert(name, "O", "URL")
	Set resp = ..GetJSON(url, .pError)
	If '$IsObject(resp) Quit ""
	Set id = ""
	If $IsObject(resp."idGroup"), $IsObject(resp."idGroup"."rxnormId") {
		If resp."idGroup"."rxnormId".%Size() > 0 Set id = resp."idGroup"."rxnormId".%Get(0)
	}
	Quit id
}

/// The drug graph around an RxNorm concept, restricted to the term types asked
/// for. This is what resolves a brand name to the clinical drugs a repository
/// actually stores.
///
/// ttyList examples: "IN+SCD+SBD" (ingredients and drugs), "BN+IN" (brand and
/// ingredient). Returns a %DynamicArray of {tty, rxcui, name}.
ClassMethod RxNormRelated(rxcui As %String, ttyList As %String = "IN+SCD+SBD", Output pError As %String) As %DynamicArray
{
	Set pError = "", out = []
	Set url = ..#RXNAV_"/REST/rxcui/"_rxcui_"/related.json?tty="_ttyList
	Set resp = ..GetJSON(url, .pError)
	If '$IsObject(resp) Quit out
	If '$IsObject(resp."relatedGroup") Quit out
	If '$IsObject(resp."relatedGroup"."conceptGroup") Quit out
	Set it = resp."relatedGroup"."conceptGroup".%GetIterator()
	While it.%GetNext(.k, .g) {
		If '$IsObject(g) Continue
		If '$IsObject(g."conceptProperties") Continue
		Set it2 = g."conceptProperties".%GetIterator()
		While it2.%GetNext(.k2, .c) {
			If '$IsObject(c) Continue
			Set row = {}
			Set row.tty = g.tty
			Set row.rxcui = c.rxcui
			Set row.name = c.name
			Do out.%Push(row)
		}
	}
	Quit out
}

/// Smoke test for all three services. Run after setting up the SSL config:
///   do ##class(INT.FHIRSQLLLM.Terminology.Client).SelfTest()
ClassMethod SelfTest() As %Status
{
	Write !,"=== terminology client self-test ===",!

	Write !,"1. $expand is-a 5689008 (Chronic periodontitis)",!
	Set arr = ..Expand("5689008", ..#SNOMED, 20, .err, .total)
	If err '= "" {
		Write "   FAILED: ",err,!
		Write "   (if this is a TLS error, check the '",..#SSLCONFIG,"' SSL configuration)",!
	}
	Else {
		Write "   total ",total,", returned ",arr.%Size(),!
		For i = 0:1:$Select(arr.%Size()>4:4, 1:arr.%Size()-1) {
			Write "     ",arr.%Get(i).code,"  ",arr.%Get(i).display,!
		}
	}

	Write !,"2. $subsumes -- descendant vs sibling",!
	Set r1 = ..Subsumes("5689008", "707251008", ..#SNOMED, .e1)
	Write "   chronic vs Generalised chronic periodontitis : ",$Select(r1'="":r1, 1:"ERR "_e1),
		"  (expect subsumes)",!
	Set r2 = ..Subsumes("5689008", "715859008", ..#SNOMED, .e2)
	Write "   chronic vs Localised moderate AGGRESSIVE     : ",$Select(r2'="":r2, 1:"ERR "_e2),
		"  (expect not-subsumed)",!

	Write !,"3. RxNav -- Augmentin to ingredients and drugs",!
	Set id = ..RxNormIdByName("Augmentin", .e3)
	If id = "" {
		Write "   FAILED: ",e3,!
	}
	Else {
		Write "   Augmentin -> rxcui ",id,!
		Set rel = ..RxNormRelated(id, "IN+SCD", .e4)
		Write "   related concepts: ",rel.%Size(),!
		For i = 0:1:$Select(rel.%Size()>5:5, 1:rel.%Size()-1) {
			Write "     ",rel.%Get(i).tty,"  ",rel.%Get(i).rxcui,"  ",rel.%Get(i).name,!
		}
	}

	Write !,"=== done ===",!
	Quit $$$OK
}

}
