/// Embeddings returned by the sidecar.
///
/// Vectors are carried as comma-separated strings: that is what TO_VECTOR()
/// consumes, and a readable trace is the point -- packed binary would show as
/// noise in Message Viewer.
Class INT.FHIRSQLLLM.Embed.Response Extends Ens.Response
{

Property Vectors As list Of %String(MAXLEN = 30000);

Property Dim As %Integer;

Property Model As %String(MAXLEN = 128);

Property LatencyMs As %Integer;

Property Error As %String(MAXLEN = 1000);

Storage Default
{
<Data name="ResponseDefaultData">
<Subscript>"Response"</Subscript>
<Value name="1">
<Value>Vectors</Value>
</Value>
<Value name="2">
<Value>Dim</Value>
</Value>
<Value name="3">
<Value>Model</Value>
</Value>
<Value name="4">
<Value>LatencyMs</Value>
</Value>
<Value name="5">
<Value>Error</Value>
</Value>
</Data>
<DefaultData>ResponseDefaultData</DefaultData>
<Type>%Storage.Persistent</Type>
}

}
