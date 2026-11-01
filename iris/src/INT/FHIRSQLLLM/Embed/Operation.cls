/// SapBERT embedding, as a traced business operation.
///
/// Calls the sidecar POST /embed. It runs outside IRIS because Embedded Python
/// cannot see a venv, and a 110M-parameter model should not share the database
/// process.
///
/// Worth knowing when reading any similarity this produces: SapBERT scores
/// "Chronic periodontitis" against "Aggressive periodontitis" at cosine 0.790,
/// HIGHER than "heart attack" against "myocardial infarction" at 0.778. These
/// vectors generate candidates; they do not decide membership.
Class INT.FHIRSQLLLM.Embed.Operation Extends Ens.BusinessOperation
{

Parameter INVOCATION = "Queue";

Property Server As %String(MAXLEN = 128) [ InitialExpression = "127.0.0.1" ];

Property Port As %Integer [ InitialExpression = 8088 ];

Property Path As %String(MAXLEN = 128) [ InitialExpression = "/embed" ];

Property CallTimeout As %Integer [ InitialExpression = 300 ];

Parameter SETTINGS = "Server:Embed,Port:Embed,Path:Embed,CallTimeout:Embed";

Method OnMessage(pRequest As INT.FHIRSQLLLM.Embed.Request, Output pResponse As INT.FHIRSQLLLM.Embed.Response) As %Status
{
	Set pResponse = ##class(INT.FHIRSQLLLM.Embed.Response).%New()
	Set start = $ZHOROLOG
	Set tSC = $$$OK

	Try {
		Set payload = {}
		Set arr = []
		For i = 1:1:pRequest.Texts.Count() {
			Do arr.%Push(pRequest.Texts.GetAt(i))
		}
		Set payload.texts = arr

		Set http = ##class(%Net.HttpRequest).%New()
		Set http.Server = ..Server
		Set http.Port = ..Port
		Set http.Timeout = ..CallTimeout
		Set http.ContentType = "application/json"
		Do http.EntityBody.Write(payload.%ToJSON())

		Set tSC = http.Post(..Path)
		If $$$ISERR(tSC) Quit

		Set resp = http.HttpResponse
		If (resp.StatusCode < 200) || (resp.StatusCode > 299) {
			Do resp.Data.Rewind()
			Set pResponse.Error = "HTTP "_resp.StatusCode_" "_resp.Data.Read(500)
		}
		Else {
			Do resp.Data.Rewind()
			Set raw = {}.%FromJSON(resp.Data)
			Set pResponse.Dim = +raw.dim
			Set pResponse.Model = "SapBERT"
			If $IsObject(raw.vectors) {
				Set it = raw.vectors.%GetIterator()
				While it.%GetNext(.k, .v) {
					If $IsObject(v) {
						Set csv = ""
						Set it2 = v.%GetIterator()
						While it2.%GetNext(.k2, .f) {
							Set csv = csv_$Select(csv = "": "", 1: ",")_f
						}
						Do pResponse.Vectors.Insert(csv)
					}
				}
			}
		}
	}
	Catch e {
		Set pResponse.Error = e.DisplayString()
	}

	Set pResponse.LatencyMs = $Normalize(($ZHOROLOG - start) * 1000, 0)
	Quit tSC
}

}
