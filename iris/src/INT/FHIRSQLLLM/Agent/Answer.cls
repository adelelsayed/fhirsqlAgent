/// The agent's reply: the SQL, the rows, and -- the point of the whole design --
/// the resolution trail showing which codes were chosen and why.
///
/// A clinician cannot check a SELECT statement, but they can check "we counted
/// these four codes as chronic periodontitis and excluded aggressive
/// periodontitis". That is what Resolution carries.
Class INT.FHIRSQLLLM.Agent.Answer Extends Ens.Response
{

Property TurnId As %String(MAXLEN = 64);

/// Plain-language answer for the chat window.
Property Summary As %String(MAXLEN = 2000);

Property SQL As %Stream.GlobalCharacter;

/// Result rows as a JSON array of objects.
Property Rows As %Stream.GlobalCharacter;

Property RowCount As %Integer [ InitialExpression = 0 ];

/// JSON array, one element per concept:
///   {phrase, domain, kept:[{code,system,display,why}], dropped:[{code,why}],
///    confidence, note}
Property Resolution As %Stream.GlobalCharacter;

/// Which model answered each pass, from the LLM responses. Shown in the UI so
/// the backend is never a mystery.
Property ModelsUsed As %String(MAXLEN = 512);

Property TotalMs As %Integer;

/// Set when the turn could not be completed. The UI shows this instead of rows.
Property Error As %String(MAXLEN = 2000);

/// False when the extract pass judged the question unanswerable from this
/// database. Carrying abstention explicitly beats inventing a query.
Property Answerable As %Boolean [ InitialExpression = 1 ];

Method SetSQL(t As %String) As %Status
{
	Set ..SQL = ##class(%Stream.GlobalCharacter).%New()
	Quit ..SQL.Write(t)
}

Method SetRows(t As %String) As %Status
{
	Set ..Rows = ##class(%Stream.GlobalCharacter).%New()
	Quit ..Rows.Write(t)
}

Method SetResolution(t As %String) As %Status
{
	Set ..Resolution = ##class(%Stream.GlobalCharacter).%New()
	Quit ..Resolution.Write(t)
}

ClassMethod StreamText(s As %Stream.Object) As %String
{
	If '$IsObject(s) Quit ""
	Do s.Rewind()
	Quit s.Read(s.Size)
}

Storage Default
{
<Data name="AnswerDefaultData">
<Subscript>"Answer"</Subscript>
<Value name="1">
<Value>TurnId</Value>
</Value>
<Value name="2">
<Value>Summary</Value>
</Value>
<Value name="3">
<Value>SQL</Value>
</Value>
<Value name="4">
<Value>Rows</Value>
</Value>
<Value name="5">
<Value>RowCount</Value>
</Value>
<Value name="6">
<Value>Resolution</Value>
</Value>
<Value name="7">
<Value>ModelsUsed</Value>
</Value>
<Value name="8">
<Value>TotalMs</Value>
</Value>
<Value name="9">
<Value>Error</Value>
</Value>
<Value name="10">
<Value>Answerable</Value>
</Value>
</Data>
<DefaultData>AnswerDefaultData</DefaultData>
<Type>%Storage.Persistent</Type>
}

}
