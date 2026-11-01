/// One LLM call, vendor-neutral.
///
/// Every pass in the agent (extract / rerank / sql) sends this same class.
/// Nothing in the orchestration knows which vendor answers it -- that is a
/// production setting on INT.FHIRSQLLLM.LLM.Operation.
Class INT.FHIRSQLLLM.LLM.Request Extends Ens.Request
{

/// Which logical pass this is. Drives per-pass model choice and logging.
Property Pass As %String(VALUELIST = ",extract,rerank,sql") [ Required ];

/// System / developer instruction.
Property SystemPrompt As %Stream.GlobalCharacter;

/// The user turn.
Property UserPrompt As %Stream.GlobalCharacter;

Property MaxTokens As %Integer [ InitialExpression = 2048 ];

/// Keep at 0 for anything we evaluate.
Property Temperature As %Numeric [ InitialExpression = 0 ];

/// Ask for strict JSON. Applied per vendor where supported, and always
/// restated in the prompt so it degrades gracefully when it is not.
Property ExpectJSON As %Boolean [ InitialExpression = 0 ];

/// Optional override; normally empty so the production setting wins.
Property ModelOverride As %String(MAXLEN = 128);

/// Correlation id so one chat turn is traceable across all passes.
Property TurnId As %String(MAXLEN = 64);

Method SetSystem(text As %String) As %Status
{
	Set ..SystemPrompt = ##class(%Stream.GlobalCharacter).%New()
	Quit ..SystemPrompt.Write(text)
}

Method SetUser(text As %String) As %Status
{
	Set ..UserPrompt = ##class(%Stream.GlobalCharacter).%New()
	Quit ..UserPrompt.Write(text)
}

Method SystemText() As %String
{
	If '$IsObject(..SystemPrompt) Quit ""
	Do ..SystemPrompt.Rewind()
	Quit ..SystemPrompt.Read(..SystemPrompt.Size)
}

Method UserText() As %String
{
	If '$IsObject(..UserPrompt) Quit ""
	Do ..UserPrompt.Rewind()
	Quit ..UserPrompt.Read(..UserPrompt.Size)
}

Storage Default
{
<Data name="RequestDefaultData">
<Subscript>"Request"</Subscript>
<Value name="1">
<Value>Pass</Value>
</Value>
<Value name="2">
<Value>SystemPrompt</Value>
</Value>
<Value name="3">
<Value>UserPrompt</Value>
</Value>
<Value name="4">
<Value>MaxTokens</Value>
</Value>
<Value name="5">
<Value>Temperature</Value>
</Value>
<Value name="6">
<Value>ExpectJSON</Value>
</Value>
<Value name="7">
<Value>ModelOverride</Value>
</Value>
<Value name="8">
<Value>TurnId</Value>
</Value>
</Data>
<DefaultData>RequestDefaultData</DefaultData>
<Type>%Storage.Persistent</Type>
}

}
