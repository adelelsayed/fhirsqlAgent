/// What an LLM pass returned. Vendor and model are recorded so the
/// Interoperability trace shows which backend actually answered each pass.
Class INT.FHIRSQLLLM.LLM.Response Extends Ens.Response
{

Property Text As %Stream.GlobalCharacter;

Property Vendor As %String(MAXLEN = 32);

Property Model As %String(MAXLEN = 128);

Property PromptTokens As %Integer;

Property CompletionTokens As %Integer;

Property LatencyMs As %Integer;

/// Set when the vendor stopped for a reason other than finishing normally
/// (for example a token-limit cutoff), so a truncated JSON reply is diagnosable.
Property StopReason As %String(MAXLEN = 64);

Method GetText() As %String
{
	If '$IsObject(..Text) Quit ""
	Do ..Text.Rewind()
	Quit ..Text.Read(..Text.Size)
}

Method SetText(text As %String) As %Status
{
	Set ..Text = ##class(%Stream.GlobalCharacter).%New()
	Quit ..Text.Write(text)
}

Storage Default
{
<Data name="ResponseDefaultData">
<Subscript>"Response"</Subscript>
<Value name="1">
<Value>Text</Value>
</Value>
<Value name="2">
<Value>Vendor</Value>
</Value>
<Value name="3">
<Value>Model</Value>
</Value>
<Value name="4">
<Value>PromptTokens</Value>
</Value>
<Value name="5">
<Value>CompletionTokens</Value>
</Value>
<Value name="6">
<Value>LatencyMs</Value>
</Value>
<Value name="7">
<Value>StopReason</Value>
</Value>
</Data>
<DefaultData>ResponseDefaultData</DefaultData>
<Type>%Storage.Persistent</Type>
}

}
