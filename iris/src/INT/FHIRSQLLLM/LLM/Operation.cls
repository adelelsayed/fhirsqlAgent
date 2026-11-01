/// Model-agnostic LLM business operation.
///
/// The operation speaks one shape -- INT.FHIRSQLLLM.LLM.Request in,
/// INT.FHIRSQLLLM.LLM.Response out -- and posts it to the local sidecar, which
/// owns the vendor payload. Changing model or vendor is therefore a production
/// setting change plus a sidecar edit, never a change to this class, to the
/// messages, or to the orchestrator.
///
/// Add one of these per pass (LLM.Extract, LLM.Rerank, LLM.SQL) so each pass can
/// run a different model and the trace records which one answered.
///
/// No credential travels with the request. The key lives in an IRIS Credentials
/// entry; Production.ExportCredential() writes it to a file on a volume shared
/// with the sidecar, which loads it itself. The token never appears in source, in
/// a setting, on a command line, or in the process list.
Class INT.FHIRSQLLLM.LLM.Operation Extends Ens.BusinessOperation
{

Parameter ADAPTER = "EnsLib.HTTP.OutboundAdapter";

Parameter INVOCATION = "Queue";

Property Adapter As EnsLib.HTTP.OutboundAdapter;

/// Only "sidecar": post to the local FastAPI service, which calls the model.
///
/// Earlier revisions of this class built the vendor payload here and signed the
/// request itself. That is deliberately gone. Keeping the vendor out of
/// ObjectScript means boto3 handles AWS SigV4 (or a bearer token, which Bedrock
/// does accept -- an earlier note here claimed otherwise and was wrong), and a
/// new vendor is a change to one Python file rather than a new branch in a
/// compiled business operation.
Property Vendor As %String(VALUELIST = ",sidecar") [ InitialExpression = "sidecar", Required ];

/// Model id as the sidecar's provider names it. For Bedrock that is an
/// inference-profile id, which carries a region prefix: us.anthropic.claude-...
Property Model As %String(MAXLEN = 128) [ Required ];

/// Path appended to the adapter's HTTPServer. Left blank uses the vendor default.
Property APIPath As %String(MAXLEN = 256);

/// Seconds. The rerank pass over a large candidate list is the slow one.
Property CallTimeout As %Integer [ InitialExpression = 120 ];

/// Host and port. Set directly rather than taken from the adapter because
/// EnsLib.HTTP.OutboundAdapter.Post() constructs its OWN %Net.HttpRequest -- its
/// third argument is pFormVarNames, not a request object -- so a body built by
/// the caller is silently discarded and the post lands on the wrong URL.
Property Server As %String(MAXLEN = 256) [ InitialExpression = "127.0.0.1" ];

Property Port As %Integer [ InitialExpression = 8088 ];

Property UseHTTPS As %Boolean [ InitialExpression = 0 ];

/// Blank for the localhost sidecar; a configuration name for a real HTTPS host.
Property SSLConfig As %String(MAXLEN = 64);

Parameter SETTINGS = "Vendor:LLM,Model:LLM,Server:LLM,Port:LLM,UseHTTPS:LLM,SSLConfig:LLM,APIPath:LLM,CallTimeout:LLM";

Method OnMessage(pRequest As INT.FHIRSQLLLM.LLM.Request, Output pResponse As INT.FHIRSQLLLM.LLM.Response) As %Status
{
	Set tSC = $$$OK
	Set pResponse = ##class(INT.FHIRSQLLLM.LLM.Response).%New()
	Set model = $Select(pRequest.ModelOverride '= "": pRequest.ModelOverride, 1: ..Model)
	Set pResponse.Vendor = ..Vendor
	Set pResponse.Model = model
	Set start = $ZHOROLOG

	Try {
		Set body = ..BuildBody(pRequest, model, .tSC)
		If $$$ISERR(tSC) Quit

		Set http = ##class(%Net.HttpRequest).%New()
		Set http.Server = ..Server
		Set http.Port = ..Port
		Set http.Https = ..UseHTTPS
		If ..SSLConfig '= "" Set http.SSLConfiguration = ..SSLConfig
		Set http.ContentType = "application/json"
		Set http.Timeout = ..CallTimeout
		Do http.SetHeader("accept", "application/json")

		Set tSC = ..ApplyAuth(http)
		If $$$ISERR(tSC) Quit

		Do http.EntityBody.Write(body.%ToJSON())

		Set tSC = http.Post(..ResolvePath())
		If $$$ISERR(tSC) Quit

		Set resp = http.HttpResponse
		If (resp.StatusCode < 200) || (resp.StatusCode > 299) {
			Do resp.Data.Rewind()
			Set err = resp.Data.Read(2000)
			Set msg = ..Vendor_" HTTP "_resp.StatusCode_" for pass '"_pRequest.Pass_"': "_err
			Set tSC = $$$ERROR($$$GeneralError, msg)
			Quit
		}

		Do resp.Data.Rewind()
		Set raw = {}.%FromJSON(resp.Data)
		Set tSC = ..ParseBody(raw, .pResponse)
	}
	Catch ex {
		Set tSC = ex.AsStatus()
	}

	Set pResponse.LatencyMs = $Normalize(($ZHOROLOG - start) * 1000, 0)
	Quit tSC
}

/// Vendor default paths, overridable by the APIPath setting.
Method ResolvePath() As %String
{
	Quit $Select(..APIPath '= "": ..APIPath, 1: "/llm")
}

/// The sidecar is on localhost and loads the Bedrock token itself from a file
/// written by Production.ExportCredential(), so no credential travels with the
/// request and there is nothing to sign here.
Method ApplyAuth(http As %Net.HttpRequest) As %Status
{
	Quit $$$OK
}

/// Build the sidecar request payload.
///
/// temperature is deliberately absent: Claude 5 models on Bedrock REJECT it
/// ("`temperature` is deprecated for this model") rather than ignoring it, so it
/// cannot be sent with a default.
Method BuildBody(pRequest As INT.FHIRSQLLLM.LLM.Request, model As %String, Output tSC As %Status) As %DynamicObject
{
	Set tSC = $$$OK
	Set sys = pRequest.SystemText()
	Set usr = pRequest.UserText()
	If pRequest.ExpectJSON {
		Set sys = sys_$Char(10,10)_"Reply with a single JSON object and nothing else. No prose, no code fences."
	}
	Set body = {}
	Set body.model = model
	Set body."max_tokens" = pRequest.MaxTokens
	If sys '= "" Set body.system = sys
	Set body.user = usr
	Quit body
}

/// Pull text, token counts and stop reason out of the sidecar response.
Method ParseBody(raw As %DynamicObject, ByRef pResponse As INT.FHIRSQLLLM.LLM.Response) As %Status
{
	Set pResponse.StopReason = raw."stop_reason"
	Set pResponse.PromptTokens = raw."input_tokens"
	Set pResponse.CompletionTokens = raw."output_tokens"
	If raw.model '= "" Set pResponse.Model = raw.model
	Quit pResponse.SetText(raw.text)
}

}
