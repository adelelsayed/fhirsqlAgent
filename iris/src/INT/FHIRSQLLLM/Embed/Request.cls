/// Ask the sidecar to embed one or more texts.
///
/// A traced message rather than an inline call, so the Interoperability log shows
/// the embedding round-trip as a step of the design: a reviewer can see exactly
/// what was embedded and what came back.
Class INT.FHIRSQLLLM.Embed.Request Extends Ens.Request
{

/// Texts to embed. One phrase for a lookup; a batch when indexing.
Property Texts As list Of %String(MAXLEN = 512);

/// Why this embedding was requested -- shown in the trace.
Property Purpose As %String(MAXLEN = 64) [ InitialExpression = "lookup" ];

Property TurnId As %String(MAXLEN = 64);

Storage Default
{
<Data name="RequestDefaultData">
<Subscript>"Request"</Subscript>
<Value name="1">
<Value>Texts</Value>
</Value>
<Value name="2">
<Value>Purpose</Value>
</Value>
<Value name="3">
<Value>TurnId</Value>
</Value>
</Data>
<DefaultData>RequestDefaultData</DefaultData>
<Type>%Storage.Persistent</Type>
}

}
