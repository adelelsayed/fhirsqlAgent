/// Dump one agent turn from the message bank as plain text.
///
/// Message Viewer already shows all of this in the browser; this exists so a
/// turn can be pasted into a write-up or a review without screenshots, and so
/// the trace can be diffed between runs.
///
///   do ##class(INT.FHIRSQLLLM.Setup.Trace).Dump(80, "/tmp/trace80.txt")
///
/// Pass no session id to dump the most recent turn.
Class INT.FHIRSQLLLM.Setup.Trace
{

/// Session ids of the most recent turns, newest first.
ClassMethod Recent(n As %Integer = 10) As %Status
{
	Set rs = ##class(%SQL.Statement).%ExecDirect(,
		"SELECT TOP ? h.SessionId, MIN(h.TimeCreated) AS Started, COUNT(*) AS Messages "_
		"FROM Ens.MessageHeader h "_
		"WHERE h.SessionId IS NOT NULL "_
		"GROUP BY h.SessionId ORDER BY h.SessionId DESC", n)
	While rs.%Next() {
		Write rs.%Get("SessionId"), "  ", rs.%Get("Started"), "  ",
		      rs.%Get("Messages"), " messages", !
	}
	Quit $$$OK
}

/// Write every message of one turn, in order, with its body expanded.
ClassMethod Dump(sessionId As %Integer = 0, path As %String = "") As %Status
{
	If sessionId = 0 {
		Set rs = ##class(%SQL.Statement).%ExecDirect(,
			"SELECT TOP 1 SessionId FROM Ens.MessageHeader "_
			"WHERE SessionId IS NOT NULL ORDER BY ID DESC")
		If rs.%Next() Set sessionId = rs.%Get("SessionId")
	}
	If sessionId = 0 Quit $$$ERROR($$$GeneralError, "no sessions in the message bank")

	Set dev = ""
	If path '= "" {
		Open path:("WNS"):10
		If '$Test Quit $$$ERROR($$$GeneralError, "cannot open "_path)
		Set dev = path
		Use dev
	}

	Write "agent turn, session ", sessionId, !
	Write "================================================================", !!

	Set rs = ##class(%SQL.Statement).%ExecDirect(,
		"SELECT ID, SourceConfigName, TargetConfigName, MessageBodyClassName, "_
		"MessageBodyId, TimeCreated FROM Ens.MessageHeader "_
		"WHERE SessionId = ? ORDER BY ID", sessionId)

	While rs.%Next() {
		Write "-----[ ", rs.%Get("ID"), " ]  ",
		      rs.%Get("SourceConfigName"), "  ->  ", rs.%Get("TargetConfigName"), !
		Write "      ", rs.%Get("MessageBodyClassName"),
		      "   ", rs.%Get("TimeCreated"), !!
		Do ..Body(rs.%Get("MessageBodyClassName"), rs.%Get("MessageBodyId"))
		Write !
	}

	If dev '= "" {
		Use 0
		Close dev
		Write "written to ", path, !
	}
	Quit $$$OK
}

/// Expand one message body. Each branch prints the fields that carry the
/// argument of the design -- prompts, candidate lists, keep/drop decisions --
/// rather than every property.
ClassMethod Body(cls As %String, id As %String) As %Status
{
	If (cls = "") || (id = "") {
		Write "      (no body)", !
		Quit $$$OK
	}
	Set o = ""
	Try {
		Set o = $classmethod(cls, "%OpenId", id)
	}
	Catch {
	}
	If '$IsObject(o) {
		Write "      (body ", id, " not readable)", !
		Quit $$$OK
	}

	If cls [ "Agent.Question" {
		Write "      question : ", o.Text, !
		Write "      turn     : ", o.TurnId, !
	}
	ElseIf cls [ "LLM.Request" {
		Write "      pass=", o.Pass, "  max_tokens=", o.MaxTokens,
		      "  expect_json=", o.ExpectJSON, !!
		Write "      --- system prompt ---", !
		Do ..Indent(o.SystemText())
		Write !, "      --- user prompt ---", !
		Do ..Indent(o.UserText())
	}
	ElseIf cls [ "LLM.Response" {
		Write "      model=", o.Model, "  prompt_tokens=", o.PromptTokens,
		      "  completion_tokens=", o.CompletionTokens,
		      "  latency_ms=", o.LatencyMs, "  stop=", o.StopReason, !!
		Write "      --- reply ---", !
		Do ..Indent(o.GetText())
	}
	ElseIf cls [ "Embed.Request" {
		Write "      purpose=", o.Purpose, !
		For i = 1:1:o.Texts.Count() {
			Write "      text[", i, "] : ", o.Texts.GetAt(i), !
		}
	}
	ElseIf cls [ "Embed.Response" {
		Write "      model=", o.Model, "  dim=", o.Dim,
		      "  vectors=", o.Vectors.Count(), "  latency_ms=", o.LatencyMs, !
		If o.Error '= "" Write "      error=", o.Error, !
		If o.Vectors.Count() > 0 {
			Write "      vector[1] : ", $Extract(o.Vectors.GetAt(1), 1, 120), " ...", !
		}
	}
	ElseIf cls [ "Vector.Request" {
		Write "      phrase=""", o.Phrase, """  top_n=", o.TopN,
		      "  domain_filter=", $Select(o.DomainFilter = "": "(none)", 1: o.DomainFilter), !
		Write "      query_vector : ", $Length(o.QueryVector), " chars of encoded doubles", !
	}
	ElseIf cls [ "Vector.Response" {
		Write "      count=", o.Count, "  top_similarity=", o.TopSimilarity,
		      "  latency_ms=", o.LatencyMs, !
		If o.Error '= "" Write "      error=", o.Error, !
		Write !, "      --- candidates ---", !
		Do ..Indent(o.GetCandidates())
	}
	ElseIf cls [ "Agent.Answer" {
		Write "      rows=", o.RowCount, "  total_ms=", o.TotalMs,
		      "  models=", o.ModelsUsed, "  answerable=", o.Answerable, !
		If o.Error '= "" Write "      error=", o.Error, !
		Write "      summary : ", o.Summary, !!
		Write "      --- sql ---", !
		Do ..Indent(##class(INT.FHIRSQLLLM.Agent.Answer).StreamText(o.SQL))
		Write !, "      --- rows ---", !
		Do ..Indent(##class(INT.FHIRSQLLLM.Agent.Answer).StreamText(o.Rows))
		Write !, "      --- resolution ---", !
		Do ..Indent(##class(INT.FHIRSQLLLM.Agent.Answer).StreamText(o.Resolution))
	}
	Else {
		Write "      (", cls, " #", id, ")", !
	}
	Quit $$$OK
}

/// Print text indented, one source line per output line.
ClassMethod Indent(text As %String, pad As %String = "      ") As %Status
{
	If text = "" {
		Write pad, "(empty)", !
		Quit $$$OK
	}
	Set rest = text
	For {
		Set nl = $Find(rest, $Char(10))
		If nl = 0 {
			Write pad, rest, !
			Quit
		}
		Write pad, $Extract(rest, 1, nl - 2), !
		Set rest = $Extract(rest, nl, *)
		If rest = "" Quit
	}
	Quit $$$OK
}

}
