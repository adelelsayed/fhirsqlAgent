/// Flat fact tables projected from the FHIR resources.
///
/// Why not query HSFHIR_X0001_S.* directly: its token columns are $LIST-encoded
/// (code, "system|code", "system|" packed into one varchar), so a plain
/// `WHERE code IN ('5689008')` never matches -- which is exactly why the first
/// working end-to-end run returned patient_count = 0 against 32 real rows.
/// Querying them needs `FOR SOME %ELEMENT(code) (%VALUE = ...)`, which is an
/// IRIS-specific idiom no general SQL model will produce.
///
/// One row per (resource, coding). A resource coded in both SNOMED and ICD-10
/// yields two rows, so a code-set filter matches whichever vocabulary the
/// resolver chose.
Class INT.FHIRSQLLLM.Projection.Fact Extends %Persistent [ DdlAllowed ]
{

/// condition | procedure | medication | observation | immunization | allergy
Property FactType As %String(MAXLEN = 32) [ Required, SqlFieldName = FactType ];

Property PatientId As %String(MAXLEN = 64);

Property ResourceId As %String(MAXLEN = 64);

Property Code As %String(MAXLEN = 64);

Property CodeSystem As %String(MAXLEN = 255);

Property Display As %String(MAXLEN = 512);

/// The clinically meaningful date for this fact type: onset for a condition,
/// performed for a procedure, authored for a medication request, effective for
/// an observation. Kept as the raw FHIR string, offset included, for display.
Property FactDate As %String(MAXLEN = 32);

/// The same instant as a real date, for arithmetic.
///
/// This exists because FactDate is a varchar holding an ISO-8601 value such as
/// "2014-04-02T22:09:33+04:00". Lexicographic >= happens to order such strings
/// correctly, so a plain comparison works and looks fine -- but any DATE
/// FUNCTION over it does not. DATEADD('day', 90, FactDate) returns SQLCODE 0
/// and ZERO ROWS, not an error and not even the COUNT row, so a temporal query
/// silently answers "none" instead of failing. Every "within N days" question
/// was wrong in exactly that invisible way until this column existed.
Property FactDay As %Date;

Index idxDay On (FactType, FactDay);

/// Observation value, when numeric.
Property ValueQuantity As %Numeric;

Property ValueUnit As %String(MAXLEN = 32);

Property Status As %String(MAXLEN = 32);

Index idxType On FactType;

Index idxCode On (FactType, Code);

Index idxPatient On PatientId;

/// Leading YYYY-MM-DD of a FHIR dateTime as a $HOROLOG day number, or "" if the
/// value is absent or not a date. $ZDateH is wrapped because a malformed date
/// throws rather than returning a sentinel, and one bad resource must not stop
/// a build of 200,000 rows.
ClassMethod DayOf(iso As %String) As %Date
{
	If $Length(iso) < 10 Quit ""
	Set d = ""
	Try { Set d = $ZDateH($Extract(iso, 1, 10), 3) } Catch { Set d = "" }
	Quit d
}

/// Where the date lives, per resource type.
ClassMethod DatePath(rt As %String) As %String
{
	If rt = "Condition" Quit "onsetDateTime,onsetPeriod,recordedDate"
	If rt = "Procedure" Quit "performedDateTime,performedPeriod"
	If rt = "MedicationRequest" Quit "authoredOn"
	If rt = "Observation" Quit "effectiveDateTime,effectivePeriod"
	If rt = "Immunization" Quit "occurrenceDateTime"
	If rt = "AllergyIntolerance" Quit "recordedDate,onsetDateTime"
	Quit ""
}

/// First of the candidate date elements that is actually present.
///
/// FHIR dates are choice types: a Procedure carries performedDateTime OR
/// performedPeriod, and Synthea writes the PERIOD form. Reading only the
/// dateTime element left every one of 36,837 procedure rows with no date, which
/// did not fail -- it just made every temporal question about a procedure
/// answer zero. A period contributes its start.
ClassMethod DateOf(obj As %DynamicObject, paths As %String) As %String
{
	Set out = ""
	For i = 1:1:$Length(paths, ",") {
		Set path = $Piece(paths, ",", i)
		If path = "" Continue
		Set v = obj.%Get(path)
		If v = "" Continue
		If $IsObject(v) {
			Set out = v.start
			If out = "" Set out = v.end
		}
		Else {
			Set out = v
		}
		If out '= "" Quit
	}
	Quit out
}

/// Rebuild every fact table from the FHIR repository.
ClassMethod Build(verbose As %Boolean = 1) As %Status
{
	&sql(DELETE FROM INT_FHIRSQLLLM_Projection.Fact)
	If verbose Write "cleared existing facts", !

	Set types = $ListBuild("Condition", "Procedure", "MedicationRequest",
		"Observation", "Immunization", "AllergyIntolerance")
	Set grand = 0
	For i = 1:1:$ListLength(types) {
		Set rt = $List(types, i)
		Set n = ..BuildOne(rt, verbose)
		Set grand = grand + n
		If verbose Write "  ", rt, ": ", n, " fact rows", !
	}
	If verbose Write "total fact rows: ", grand, !
	Quit $$$OK
}

ClassMethod BuildOne(rt As %String, verbose As %Boolean = 1) As %Integer
{
	Set codePath = ##class(INT.FHIRSQLLLM.Terminology.Loader).CodePath(rt)
	If codePath = "" Quit 0
	Set factType = ##class(INT.FHIRSQLLLM.Terminology.Loader).Domain(rt)
	Set datePath = ..DatePath(rt)

	Set rs = ##class(%SQL.Statement).%ExecDirect(,
		"SELECT ResourceString, ResourceStream FROM HSFHIR_X0001_R.Rsrc "_
		"WHERE ResourceType = ? AND Deleted = 0", rt)
	If rs.%SQLCODE < 0 {
		If verbose Write "  !! ", rt, ": SQLCODE ", rs.%SQLCODE, !
		Quit 0
	}

	Set n = 0
	While rs.%Next() {
		Set json = rs.%Get("ResourceString")
		If json = "" {
			Set st = rs.%Get("ResourceStream")
			If $IsObject(st) {
				Do st.Rewind()
				Set json = st.Read(st.Size)
			}
		}
		If json = "" Continue
		Try { Set obj = {}.%FromJSON(json) } Catch { Continue }
		If '$IsObject(obj) Continue

		Set cc = obj.%Get(codePath)
		If '$IsObject(cc) Continue
		If '$IsObject(cc.coding) Continue

		// patient reference, named differently per resource type
		Set pat = ""
		For prop = "subject", "patient" {
			Set ref = obj.%Get(prop)
			If $IsObject(ref), ref.reference '= "" {
				Set pat = $Piece(ref.reference, "/", 2)
				Quit
			}
		}

		Set fdate = ""
		If datePath '= "" Set fdate = ..DateOf(obj, datePath)
		Set status = obj.%Get("status")
		If status = "" {
			Set cs = obj.%Get("clinicalStatus")
			If $IsObject(cs), $IsObject(cs.coding), cs.coding.%Size() > 0 {
				Set status = cs.coding.%Get(0).code
			}
		}

		Set vq = "", vu = ""
		Set v = obj.%Get("valueQuantity")
		If $IsObject(v) {
			Set vq = v.value
			Set vu = v.unit
		}

		Set it = cc.coding.%GetIterator()
		While it.%GetNext(.k, .c) {
			If '$IsObject(c) Continue
			If c.code = "" Continue
			Set f = ..%New()
			Set f.FactType = factType
			Set f.PatientId = pat
			Set f.ResourceId = obj.id
			Set f.Code = c.code
			Set f.CodeSystem = c.system
			Set f.Display = c.display
			Set f.FactDate = fdate
			Set f.FactDay = ..DayOf(fdate)
			Set f.Status = status
			If vq '= "" Set f.ValueQuantity = vq
			Set f.ValueUnit = vu
			If $$$ISOK(f.%Save()) Set n = n + 1
		}
	}
	Quit n
}

/// What the projection holds. Also the schema the SQL pass is shown.
ClassMethod Report() As %Status
{
	Write !, "=== INT_FHIRSQLLLM_Projection.Fact ===", !
	Set rs = ##class(%SQL.Statement).%ExecDirect(,
		"SELECT FactType, COUNT(*) AS N, COUNT(DISTINCT PatientId) AS Pts, "_
		"COUNT(DISTINCT Code) AS Codes FROM INT_FHIRSQLLLM_Projection.Fact "_
		"GROUP BY FactType ORDER BY 2 DESC")
	While rs.%Next() {
		Write "  ", $Justify(rs.%Get("N"), 8), " rows  ",
			$Justify(rs.%Get("Pts"), 5), " patients  ",
			$Justify(rs.%Get("Codes"), 5), " codes   ", rs.%Get("FactType"), !
	}
	Quit $$$OK
}

Storage Default
{
<Data name="FactDefaultData">
<Value name="1">
<Value>%%CLASSNAME</Value>
</Value>
<Value name="2">
<Value>FactType</Value>
</Value>
<Value name="3">
<Value>PatientId</Value>
</Value>
<Value name="4">
<Value>ResourceId</Value>
</Value>
<Value name="5">
<Value>Code</Value>
</Value>
<Value name="6">
<Value>CodeSystem</Value>
</Value>
<Value name="7">
<Value>Display</Value>
</Value>
<Value name="8">
<Value>FactDate</Value>
</Value>
<Value name="9">
<Value>ValueQuantity</Value>
</Value>
<Value name="10">
<Value>ValueUnit</Value>
</Value>
<Value name="11">
<Value>Status</Value>
</Value>
</Data>
<DataLocation>^INT.FHIRSQLLLM.ProjD</DataLocation>
<DefaultData>FactDefaultData</DefaultData>
<IdLocation>^INT.FHIRSQLLLM.ProjD</IdLocation>
<IndexLocation>^INT.FHIRSQLLLM.ProjI</IndexLocation>
<StreamLocation>^INT.FHIRSQLLLM.ProjS</StreamLocation>
<Type>%Storage.Persistent</Type>
}

}
