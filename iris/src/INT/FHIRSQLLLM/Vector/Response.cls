/// Ranked concepts from the vector search, with similarity scores.
///
/// Candidates is a JSON array of
///   {code, system, systemUri, display, occurrences, ambiguous, similarity}
/// which is the shape the rerank prompt consumes directly.
Class INT.FHIRSQLLLM.Vector.Response Extends Ens.Response
{

Property Candidates As %Stream.GlobalCharacter;

Property Count As %Integer [ InitialExpression = 0 ];

Property TopSimilarity As %Numeric;

Property LatencyMs As %Integer;

Property Error As %String(MAXLEN = 1000);

Method SetCandidates(json As %String) As %Status
{
	Set ..Candidates = ##class(%Stream.GlobalCharacter).%New()
	Quit ..Candidates.Write(json)
}

Method GetCandidates() As %String
{
	If '$IsObject(..Candidates) Quit "[]"
	Do ..Candidates.Rewind()
	Quit ..Candidates.Read(..Candidates.Size)
}

Storage Default
{
<Data name="ResponseDefaultData">
<Subscript>"Response"</Subscript>
<Value name="1">
<Value>Candidates</Value>
</Value>
<Value name="2">
<Value>Count</Value>
</Value>
<Value name="3">
<Value>TopSimilarity</Value>
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
