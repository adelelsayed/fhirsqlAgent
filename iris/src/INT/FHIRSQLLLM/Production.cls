/// The production: one LLM business operation per pass, plus the agent process.
///
/// Separate operations rather than one shared component, for three reasons:
///   * each pass can run a different model -- the ML4H 2026 result was four
///     backbones within 4 pp, a 12B model not beaten by a 743B one, so model
///     choice per pass is a setting worth having
///   * the Interoperability trace records which model answered which pass
///   * one pass can be retargeted (cheaper model for extract, stronger for
///     rerank) without touching the others
///
/// Start it:
///   do ##class(INT.FHIRSQLLLM.Production).Start()
///
/// The API key is NOT here. It lives in the Credentials entry named by
/// SETTING "Credentials" on each operation's adapter.
Class INT.FHIRSQLLLM.Production Extends Ens.Production
{

Parameter CREDENTIALS = "ClaudeAPI";

Parameter BEDROCKHOST = "bedrock-runtime.us-east-1.amazonaws.com";

/// Set this once you have run:
///   aws bedrock list-foundation-models --region us-east-1 \
///     --query "modelSummaries[?contains(modelId,'anthropic')].modelId"
/// Bedrock ids are not the Anthropic API names -- they carry version suffixes
/// and cross-region profiles use a "us." prefix.
Parameter MODEL = "us.anthropic.claude-sonnet-5";

XData ProductionDefinition
{
<Production Name="INT.FHIRSQLLLM.Production" LogGeneralTraceEvents="false">
  <Description>FHIR NL-to-SQL agent: extract, rerank, generate SQL</Description>
  <ActorPoolSize>3</ActorPoolSize>

  <Item Name="Agent.Service" Category="agent"
        ClassName="INT.FHIRSQLLLM.Agent.Service"
        PoolSize="0" Enabled="true" Foreground="false" InactivityTimeout="0">
    <Setting Target="Host" Name="TargetProcess">Agent.Process</Setting>
  </Item>

  <Item Name="Agent.Process" Category="agent"
        ClassName="INT.FHIRSQLLLM.Agent.Process"
        PoolSize="1" Enabled="true" Foreground="false" InactivityTimeout="0">
    <Setting Target="Host" Name="ExtractTarget">LLM.Extract</Setting>
    <Setting Target="Host" Name="RerankTarget">LLM.Rerank</Setting>
    <Setting Target="Host" Name="SQLTarget">LLM.SQL</Setting>
    <Setting Target="Host" Name="EmbedTarget">Embed.Op</Setting>
    <Setting Target="Host" Name="VectorTarget">Vector.Op</Setting>
    <Setting Target="Host" Name="TableSchema">INT_FHIRSQLLLM_Projection</Setting>
    <Setting Target="Host" Name="MaxCandidates">120</Setting>
    <Setting Target="Host" Name="MaxRows">200</Setting>
  </Item>

  <Item Name="Embed.Op" Category="terminology"
        ClassName="INT.FHIRSQLLLM.Embed.Operation"
        PoolSize="2" Enabled="true" Foreground="false" InactivityTimeout="0">
    <Setting Target="Host" Name="Server">127.0.0.1</Setting>
    <Setting Target="Host" Name="Port">8088</Setting>
    <Setting Target="Host" Name="Path">/embed</Setting>
    <Setting Target="Host" Name="CallTimeout">300</Setting>
  </Item>

  <Item Name="Vector.Op" Category="terminology"
        ClassName="INT.FHIRSQLLLM.Vector.Operation"
        PoolSize="2" Enabled="true" Foreground="false" InactivityTimeout="0">
    <Setting Target="Host" Name="ConceptTable">INT_FHIRSQLLLM_Terminology.Concept</Setting>
    <Setting Target="Host" Name="MinSimilarity">0.45</Setting>
  </Item>

  <Item Name="LLM.Extract" Category="llm"
        ClassName="INT.FHIRSQLLLM.LLM.Operation"
        PoolSize="1" Enabled="true" Foreground="false" InactivityTimeout="0">
    <Setting Target="Host" Name="Vendor">sidecar</Setting>
    <Setting Target="Host" Name="Model">us.anthropic.claude-sonnet-5</Setting>
    <Setting Target="Host" Name="APIPath">/llm</Setting>
    <Setting Target="Host" Name="CallTimeout">60</Setting>
    <Setting Target="Host" Name="Server">127.0.0.1</Setting>
    <Setting Target="Host" Name="Port">8088</Setting>
    <Setting Target="Host" Name="UseHTTPS">0</Setting>
  </Item>

  <Item Name="LLM.Rerank" Category="llm"
        ClassName="INT.FHIRSQLLLM.LLM.Operation"
        PoolSize="2" Enabled="true" Foreground="false" InactivityTimeout="0">
    <Setting Target="Host" Name="Vendor">sidecar</Setting>
    <Setting Target="Host" Name="Model">us.anthropic.claude-sonnet-5</Setting>
    <Setting Target="Host" Name="APIPath">/llm</Setting>
    <Setting Target="Host" Name="CallTimeout">120</Setting>
    <Setting Target="Host" Name="Server">127.0.0.1</Setting>
    <Setting Target="Host" Name="Port">8088</Setting>
    <Setting Target="Host" Name="UseHTTPS">0</Setting>
  </Item>

  <Item Name="LLM.SQL" Category="llm"
        ClassName="INT.FHIRSQLLLM.LLM.Operation"
        PoolSize="1" Enabled="true" Foreground="false" InactivityTimeout="0">
    <Setting Target="Host" Name="Vendor">sidecar</Setting>
    <Setting Target="Host" Name="Model">us.anthropic.claude-sonnet-5</Setting>
    <Setting Target="Host" Name="APIPath">/llm</Setting>
    <Setting Target="Host" Name="CallTimeout">90</Setting>
    <Setting Target="Host" Name="Server">127.0.0.1</Setting>
    <Setting Target="Host" Name="Port">8088</Setting>
    <Setting Target="Host" Name="UseHTTPS">0</Setting>
  </Item>
</Production>
}

/// Apply the Bedrock model id to all three passes at once, so it is set in one
/// place rather than three.
ClassMethod SetModel(modelId As %String) As %Status
{
	Set tSC = $$$OK
	For item = "LLM.Extract", "LLM.Rerank", "LLM.SQL" {
		Set sc = ##class(Ens.Director).SetHostSetting(item, "Model", modelId)
		If $$$ISERR(sc) {
			Write "  ", item, ": ", $System.Status.GetErrorText(sc), !
			Set tSC = sc
		}
		Else {
			Write "  ", item, " -> ", modelId, !
		}
	}
	Quit tSC
}

/// Probe candidate Bedrock model ids against the runtime invoke endpoint.
///
/// A Bedrock API key is scoped to bedrock-runtime, not to the control plane, so
/// ListFoundationModels returns 403 and the id cannot be discovered that way.
/// Invoking with a minimal body is the cheapest reliable probe: the HTTP status
/// and error code tell you which ids exist and which you have access to.
ClassMethod ProbeModels(candidates As %String = "") As %Status
{
	If candidates = "" {
		Set candidates =
			"us.anthropic.claude-sonnet-5-v1:0,"_
			"anthropic.claude-sonnet-5-v1:0,"_
			"us.anthropic.claude-opus-5-v1:0,"_
			"us.anthropic.claude-sonnet-4-5-20250929-v1:0,"_
			"anthropic.claude-sonnet-4-5-20250929-v1:0,"_
			"us.anthropic.claude-3-5-sonnet-20241022-v2:0,"_
			"anthropic.claude-3-5-sonnet-20240620-v1:0"
	}
	Set cred = ##class(Ens.Config.Credentials).%OpenId(..#CREDENTIALS)
	If '$IsObject(cred) {
		Write "cannot open credential ", ..#CREDENTIALS, !
		Quit $$$OK
	}

	Set body = {}
	Set body."anthropic_version" = "bedrock-2023-05-31"
	Set body."max_tokens" = 16
	Set msg = {"role":"user"}
	Set msg.content = "Reply with the single word: ok"
	Set body.messages = [].%Push(msg)
	Set payload = body.%ToJSON()

	Write !, "=== probing ", $Length(candidates, ","), " candidate model ids ===", !
	For i = 1:1:$Length(candidates, ",") {
		Set id = $ZStrip($Piece(candidates, ",", i), "<>W")
		If id = "" Continue
		Set req = ##class(%Net.HttpRequest).%New()
		Set req.Server = ..#BEDROCKHOST
		Set req.Https = 1
		Set req.SSLConfiguration = "LLMClient"
		Set req.Timeout = 45
		Set req.ContentType = "application/json"
		Do req.SetHeader("Authorization", "Bearer "_cred.Password)
		Do req.SetHeader("accept", "application/json")
		Do req.EntityBody.Write(payload)
		Set sc = req.Post("/model/"_id_"/invoke")
		Set code = ""
		Set detail = ""
		If $$$ISOK(sc) {
			Set code = req.HttpResponse.StatusCode
			Do req.HttpResponse.Data.Rewind()
			Set detail = $Extract(req.HttpResponse.Data.Read(300), 1, 160)
		}
		Else {
			Set detail = $System.Status.GetErrorText(sc)
		}
		Write $Select(code = 200: "  WORKS  ", 1: "  no     "), $Justify(code, 4), "  ", id, !
		If code '= 200, detail '= "" Write "            ", $Replace(detail, $Char(10), " "), !
	}
	Write !, "If one says WORKS, set it:  do ##class(INT.FHIRSQLLLM.Production).SetModel(""<id>"")", !
	Quit $$$OK
}

/// Write the Bedrock token from the IRIS credential store to a locked-down file
/// the sidecar reads. The secret moves IRIS -> file inside the container; it
/// never passes through a shell, a command line, or the process list.
///
/// Returns the byte length written so the caller can confirm without printing
/// the value.
ClassMethod ExportCredential(path As %String = "/shared/.bedrock_token") As %Status
{
	Set cred = ##class(Ens.Config.Credentials).%OpenId(..#CREDENTIALS)
	If '$IsObject(cred) {
		Quit $$$ERROR($$$GeneralError, "no credential named "_..#CREDENTIALS)
	}
	If cred.Password = "" {
		Quit $$$ERROR($$$GeneralError, "credential "_..#CREDENTIALS_" has an empty password")
	}
	Set f = ##class(%Stream.FileCharacter).%New()
	Set sc = f.LinkToFile(path)
	If $$$ISERR(sc) Quit sc
	Do f.Write(cred.Password)
	Set sc = f.%Save()
	If $$$ISERR(sc) Quit sc
	// owner read/write only
	Do ##class(%File).SetAttributes(path, 384)
	Write "wrote ", $Length(cred.Password), " bytes to ", path, " (value not printed)", !
	Quit $$$OK
}

ClassMethod Start() As %Status
{
	Set sc = ##class(Ens.Director).StartProduction("INT.FHIRSQLLLM.Production")
	Write "start: ", $Select($$$ISOK(sc): "OK", 1: $System.Status.GetErrorText(sc)), !
	Quit sc
}

ClassMethod Stop() As %Status
{
	Quit ##class(Ens.Director).StopProduction()
}

/// One question end to end, from a terminal. The quickest way to see whether
/// the whole chain works.
ClassMethod Ask(question As %String, explainOnly As %Boolean = 0) As %Status
{
	Set req = ##class(INT.FHIRSQLLLM.Agent.Question).%New()
	Set req.Text = question
	Set req.ExplainOnly = explainOnly
	Set req.TurnId = $System.Util.CreateGUID()

	Write !, "Q: ", question, !
	Set rsp = ##class(INT.FHIRSQLLLM.Agent.Service).Ask(question, explainOnly, .err, .sessionId)
	If '$IsObject(rsp) {
		Write "ERROR: ", err, !
		Quit $$$OK
	}

	Write "session   : ", $Get(sessionId), !
	Write "models    : ", rsp.ModelsUsed, !
	Write "elapsed   : ", rsp.TotalMs, " ms", !
	If rsp.Error '= "" Write "ERROR     : ", rsp.Error, !
	If rsp.Summary '= "" Write "summary   : ", rsp.Summary, !
	Write "rows      : ", rsp.RowCount, !
	Write !, "SQL:", !, ##class(INT.FHIRSQLLLM.Agent.Answer).StreamText(rsp.SQL), !
	Write !, "RESOLUTION:", !, ##class(INT.FHIRSQLLLM.Agent.Answer).StreamText(rsp.Resolution), !
	If rsp.RowCount > 0 {
		Write !, "ROWS:", !, $Extract(##class(INT.FHIRSQLLLM.Agent.Answer).StreamText(rsp.Rows), 1, 1500), !
	}
	Quit $$$OK
}

}
