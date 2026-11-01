/// Nearest-concept search over the embedded terminology.
Class INT.FHIRSQLLLM.Vector.Request Extends Ens.Request
{

/// The query vector, comma separated, as produced by Embed.Operation. Carrying
/// the vector in the message rather than re-embedding here is deliberate: the
/// trace then shows embedding and search as two separate, inspectable steps.
Property QueryVector As %String(MAXLEN = 30000) [ Required ];

/// The phrase it came from, kept for readability in the trace.
Property Phrase As %String(MAXLEN = 512);

Property TopN As %Integer [ InitialExpression = 20 ];

/// Optional domain filter. Blank by default on purpose: a foreign-domain code
/// cannot survive the join in the generated SQL, so over-retrieving across
/// domains is harmless, while pre-scoping risks missing the concept entirely.
Property DomainFilter As %String(MAXLEN = 64);

Property TurnId As %String(MAXLEN = 64);

Storage Default
{
<Data name="RequestDefaultData">
<Subscript>"Request"</Subscript>
<Value name="1">
<Value>QueryVector</Value>
</Value>
<Value name="2">
<Value>Phrase</Value>
</Value>
<Value name="3">
<Value>TopN</Value>
</Value>
<Value name="4">
<Value>DomainFilter</Value>
</Value>
<Value name="5">
<Value>TurnId</Value>
</Value>
</Data>
<DefaultData>RequestDefaultData</DefaultData>
<Type>%Storage.Persistent</Type>
}

}
