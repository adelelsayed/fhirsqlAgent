/// Inbound business service: the production's front door.
///
/// Previously the CSP page reached the process through
/// EnsLib.Testing.Service.SendTestRequest(). That is a testing shim -- it works,
/// but it is not an inbound path, it does not belong in a production, and it
/// gives the trace a misleading origin. This is the proper entry point: a real
/// business service, so every chat turn starts a genuine Interoperability
/// session that Message Viewer shows end to end.
///
/// Invoked programmatically rather than by an adapter, because the caller is a
/// CSP page in the same namespace:
///
///   set sc = ##class(Ens.Director).CreateBusinessService("Agent.Service", .svc)
///   set sc = svc.ProcessInput(request, .response)
Class INT.FHIRSQLLLM.Agent.Service Extends Ens.BusinessService
{

/// No adapter: this service is called in-process by the UI, not polled.
Parameter ADAPTER = "";

/// Where questions go. A setting so the chain can be retargeted without code.
Property TargetProcess As %String [ InitialExpression = "Agent.Process" ];

Parameter SETTINGS = "TargetProcess:Agent";

Method OnProcessInput(pInput As INT.FHIRSQLLLM.Agent.Question, Output pOutput As INT.FHIRSQLLLM.Agent.Answer) As %Status
{
	Set pOutput = ""
	If '$IsObject(pInput) {
		Quit $$$ERROR($$$GeneralError, "no question supplied")
	}
	If pInput.Text = "" {
		Quit $$$ERROR($$$GeneralError, "empty question")
	}
	If pInput.TurnId = "" Set pInput.TurnId = $System.Util.CreateGUID()

	// Synchronous: the UI is waiting. The process does the three LLM passes.
	Quit ..SendRequestSync(..TargetProcess, pInput, .pOutput)
}

/// Convenience wrapper so callers do not repeat the Director dance.
/// Returns the Answer, or "" with the reason in pError.
ClassMethod Ask(question As %String, explainOnly As %Boolean = 0, Output pError As %String, Output pSessionId As %String) As INT.FHIRSQLLLM.Agent.Answer
{
	Set pError = "", pSessionId = ""
	Set req = ##class(INT.FHIRSQLLLM.Agent.Question).%New()
	Set req.Text = question
	Set req.ExplainOnly = explainOnly
	Set req.TurnId = $System.Util.CreateGUID()

	Set sc = ##class(Ens.Director).CreateBusinessService("Agent.Service", .svc)
	If $$$ISERR(sc) {
		Set pError = "cannot create Agent.Service (is the production running?): "_
			$System.Status.GetErrorText(sc)
		Quit ""
	}

	Set sc = svc.ProcessInput(req, .rsp)
	Set pSessionId = svc.%SessionId
	If $$$ISERR(sc) {
		Set pError = $System.Status.GetErrorText(sc)
		Quit ""
	}
	If '$IsObject(rsp) {
		Set pError = "no response from "_svc.TargetProcess
		Quit ""
	}
	Quit rsp
}

}
