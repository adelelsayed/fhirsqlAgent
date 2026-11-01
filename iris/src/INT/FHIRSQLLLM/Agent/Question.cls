/// A clinician's question arriving from the chat UI.
Class INT.FHIRSQLLLM.Agent.Question Extends Ens.Request
{

Property Text As %String(MAXLEN = 4000) [ Required ];

/// Correlates every pass of one chat turn in the Interoperability trace.
Property TurnId As %String(MAXLEN = 64);

/// Who asked, for the audit trail. Never sent to any model.
Property UserName As %String(MAXLEN = 128);

/// Stop before executing the SQL. Useful for the demo: show the resolution and
/// the query, let the user approve, then run it.
Property ExplainOnly As %Boolean [ InitialExpression = 0 ];

Storage Default
{
<Data name="QuestionDefaultData">
<Subscript>"Question"</Subscript>
<Value name="1">
<Value>Text</Value>
</Value>
<Value name="2">
<Value>TurnId</Value>
</Value>
<Value name="3">
<Value>UserName</Value>
</Value>
<Value name="4">
<Value>ExplainOnly</Value>
</Value>
</Data>
<DefaultData>QuestionDefaultData</DefaultData>
<Type>%Storage.Persistent</Type>
}

}
