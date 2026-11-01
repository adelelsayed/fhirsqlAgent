/// Deterministic check on generated SQL before it touches the database.
///
/// The prompt tells the model to produce a read-only SELECT. This enforces it,
/// because a prompt is a request and a gate is a guarantee. Nothing executes
/// unless Check() returns OK.
Class INT.FHIRSQLLLM.Agent.SqlGuard
{

/// Statement types and constructs that must never appear.
Parameter FORBIDDEN = "INSERT,UPDATE,DELETE,DROP,ALTER,CREATE,TRUNCATE,GRANT,REVOKE,MERGE,CALL,EXEC,EXECUTE,%CHECKPRIV,BACKUP,RESTORE,SHUTDOWN";

/// Normalise whitespace, strip markdown fences and a trailing semicolon.
ClassMethod Clean(sql As %String) As %String
{
	Set s = sql
	// models sometimes wrap in ```sql ... ``` despite being told not to
	If s [ "```" {
		Set s = $Replace(s, "```sql", "")
		Set s = $Replace(s, "```SQL", "")
		Set s = $Replace(s, "```", "")
	}
	Set s = $ZStrip(s, "<>WC")
	// drop a single trailing semicolon
	If $Extract(s, *) = ";" Set s = $Extract(s, 1, *-1)
	Set s = $ZStrip(s, "<>WC")
	Quit s
}

/// Returns $$$OK when the statement is safe to run, otherwise an error naming
/// the reason. pClean receives the cleaned statement.
ClassMethod Check(sql As %String, Output pClean As %String) As %Status
{
	Set pClean = ..Clean(sql)
	If pClean = "" Quit $$$ERROR($$$GeneralError, "empty statement")

	Set upper = $ZConvert(pClean, "U")

	// must start with SELECT or an opening parenthesis / WITH clause
	If '((upper [ "SELECT") && (($Extract(upper,1,6) = "SELECT") || ($Extract(upper,1,4) = "WITH") || ($Extract(upper,1,1) = "("))) {
		Quit $$$ERROR($$$GeneralError, "statement must begin with SELECT or WITH")
	}

	// one statement only: no semicolon anywhere after cleaning
	If pClean [ ";" Quit $$$ERROR($$$GeneralError, "multiple statements are not allowed")

	// no comment syntax, which is the usual way to smuggle something past a scan
	If (pClean [ "--") || (pClean [ "/*") {
		Quit $$$ERROR($$$GeneralError, "comments are not allowed in generated SQL")
	}

	// forbidden keywords, matched on word boundaries so column names like
	// "created" or "updated_at" do not trip the check
	Set bad = ""
	For i = 1:1:$Length(..#FORBIDDEN, ",") {
		Set kw = $Piece(..#FORBIDDEN, ",", i)
		If ..HasWord(upper, kw) {
			Set bad = kw
			Quit
		}
	}
	If bad '= "" {
		Quit $$$ERROR($$$GeneralError, "forbidden keyword in generated SQL: "_bad)
	}

	Quit $$$OK
}

/// Word-boundary keyword test. Avoids false positives on substrings.
ClassMethod HasWord(upper As %String, word As %String) As %Boolean
{
	Set pos = 0
	For {
		Set pos = $Find(upper, word, pos)
		If pos = 0 Quit
		Set beforeCh = $Extract(upper, pos - $Length(word) - 1)
		Set afterCh = $Extract(upper, pos)
		If ..IsBoundary(beforeCh), ..IsBoundary(afterCh) Quit
	}
	Quit (pos > 0)
}

ClassMethod IsBoundary(ch As %String) As %Boolean
{
	If ch = "" Quit 1
	Quit '(((ch '< "A") && (ch '> "Z")) || ((ch '< "0") && (ch '> "9")) || (ch = "_"))
}

/// Self-test covering the cases that matter.
ClassMethod SelfTest() As %Status
{
	Set cases = 7
	Set c(1) = $ListBuild("SELECT COUNT(*) FROM Foo", 1)
	Set c(2) = $ListBuild("```sql"_$Char(10)_"SELECT 1 FROM Foo"_$Char(10)_"```", 1)
	Set c(3) = $ListBuild("SELECT * FROM Foo;", 1)
	Set c(4) = $ListBuild("DROP TABLE Foo", 0)
	Set c(5) = $ListBuild("SELECT 1 FROM Foo; DELETE FROM Foo", 0)
	Set c(6) = $ListBuild("SELECT created_at, updated FROM Foo", 1)
	Set c(7) = $ListBuild("SELECT 1 FROM Foo -- sneaky", 0)

	Write !,"=== SqlGuard self-test ===",!
	Set pass = 0
	For i = 1:1:cases {
		Set sql = $List(c(i), 1)
		Set expectOK = $List(c(i), 2)
		Set sc = ..Check(sql, .clean)
		Set gotOK = $$$ISOK(sc)
		Set ok = (gotOK = expectOK)
		Set pass = pass + ok
		Write $Select(ok:"  ok   ", 1:"  FAIL "),
			"expect=", $Select(expectOK:"allow", 1:"block"),
			"  got=", $Select(gotOK:"allow", 1:"block"),
			"  ", $Extract($Replace(sql, $Char(10), " "), 1, 46), !
		If 'gotOK, 'expectOK Write "          reason: ", $System.Status.GetErrorText(sc), !
	}
	Write "  ", pass, "/", cases, " passed", !
	Quit $$$OK
}

}
