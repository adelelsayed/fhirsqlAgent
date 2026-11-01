/// Prompts for the three LLM passes, kept in one place so they are versionable
/// and reviewable rather than buried in orchestration code.
///
/// Design rule: the model is never asked to RECALL a clinical code. It extracts,
/// it chooses among candidates it was shown, and it composes SQL from codes it
/// was given. Published evidence for why:
///   * a frozen frontier model emitting value-set codes returns 48.6% codes that
///     do not exist in the reference vocabulary (RASC, arXiv:2604.14616)
///   * in an OMOP cohort study a model alone wrote vocabulary codes where
///     concept identifiers were required, and 79 of 84 executed definitions
///     returned no patients (ML4H 2026)
Class INT.FHIRSQLLLM.Agent.Prompts
{

/// PASS 1 -- extract. Question in, structured entities and query dimensions out.
/// No codes are requested here; the model does not know them and must not guess.
ClassMethod Extract() As %String
{
	Set p = "You read a clinician's question about a patient database and break it into parts."_$C(10,10)
	Set p = p_"Return JSON only, with this shape:"_$C(10)
	Set p = p_"{"_$C(10)
	Set p = p_"  ""entities"": ["_$C(10)
	Set p = p_"    {""phrase"": ""the words used in the question"","_$C(10)
	Set p = p_"     ""domain"": ""condition|procedure|medication|observation|immunization|allergy"","_$C(10)
	Set p = p_"     ""synonyms"": [""alternative clinical names for the same thing""],"_$C(10)
	Set p = p_"     ""specific_terms"": [""more specific terms the question implies""]}"_$C(10)
	Set p = p_"  ],"_$C(10)
	Set p = p_"  ""dimensions"": {"_$C(10)
	Set p = p_"    ""aggregation"": ""count_patients|count_rows|list_patients|average|min|max|none"","_$C(10)
	Set p = p_"    ""temporal"": null or {""type"":""ordering|window|recency"","_$C(10)
	Set p = p_"                            ""before"": ""phrase"", ""after"": ""phrase"","_$C(10)
	Set p = p_"                            ""window_days"": number or null},"_$C(10)
	Set p = p_"    ""group_by"": null or ""gender|age|year|month"""_$C(10)
	Set p = p_"  },"_$C(10)
	Set p = p_"  ""answerable"": true or false,"_$C(10)
	Set p = p_"  ""reason_if_not"": ""short reason"""_$C(10)
	Set p = p_"}"_$C(10,10)

	Set p = p_"Rules."_$C(10)
	Set p = p_"1. Do NOT output any clinical codes. You do not know them. A later stage looks them up."_$C(10)
	Set p = p_"2. ""synonyms"" is where you earn your keep. A word in the question is often not the"_$C(10)
	Set p = p_"   word the database stores. Give the clinical names a terminology would use."_$C(10)
	Set p = p_"   Brand drug -> its ingredients: ""Augmentin"" -> [""amoxicillin clavulanate"", ""amoxicillin""]."_$C(10)
	Set p = p_"   Abbreviation -> its expansion: ""MI"" -> [""myocardial infarction""]."_$C(10)
	Set p = p_"   Everyday word -> the clinical term: ""heart attack"" -> [""myocardial infarction""]."_$C(10)
	Set p = p_"3. ""specific_terms"" is for VAGUE words that the rest of the question makes specific."_$C(10)
	Set p = p_"   ""surgery"" in a question about appendicitis patients implies [""appendectomy"","_$C(10)
	Set p = p_"   ""excision of appendix""]. Keep the original phrase too -- you are ADDING"_$C(10)
	Set p = p_"   possibilities, not replacing them. If the word is already specific, use []."_$C(10)
	Set p = p_"4. Set answerable=false only when the database could not hold the answer at all"_$C(10)
	Set p = p_"   (a question about cost, staffing, or something outside clinical records)."_$C(10)
	Quit p
}

/// PASS 2 -- rerank. Shown the question and candidate codes retrieved from the
/// terminology, decide which ones belong.
///
/// This is the quality-critical pass, and the measurements say why it has to
/// exist. Candidates arrive from a lexical match, a vector search and a hierarchy
/// walk, so they include a concept's descendants AND its siblings -- and siblings
/// are usually different diseases. Similarity cannot separate them: SapBERT
/// scores chronic vs AGGRESSIVE periodontitis at 0.790, higher than "heart
/// attack" vs "myocardial infarction" at 0.778, which are the same disease. So no
/// cosine threshold works, and precision has to come from here and from
/// $subsumes. Left unfiltered, a LIKE '%periodontitis%' candidate set put 4 of 50
/// patient rows wrong -- 8%, with nothing in the output to say so.
ClassMethod Rerank() As %String
{
	Set p = "You decide which clinical codes belong to a concept in a clinician's question."_$C(10,10)
	Set p = p_"You are given the question and a list of candidate codes retrieved from the"_$C(10)
	Set p = p_"terminology. Some are right, some are near-misses. Choose."_$C(10,10)
	Set p = p_"Return JSON only:"_$C(10)
	Set p = p_"{"_$C(10)
	Set p = p_"  ""keep"": [{""code"":""..."", ""system"":""..."", ""why"":""a few words""}],"_$C(10)
	Set p = p_"  ""drop"": [{""code"":""..."", ""why"":""a few words""}],"_$C(10)
	Set p = p_"  ""confidence"": ""high|medium|low"","_$C(10)
	Set p = p_"  ""note"": ""anything the user should know, or null"""_$C(10)
	Set p = p_"}"_$C(10,10)

	Set p = p_"Rules."_$C(10)
	Set p = p_"1. Keep a code only if a clinician asking this question would want those patients"_$C(10)
	Set p = p_"   counted. When unsure, DROP it and say so in ""note"". A wrong extra code changes"_$C(10)
	Set p = p_"   which patients are returned and nobody sees the error."_$C(10)
	Set p = p_"2. Keep more specific forms of the concept. ""Chronic periodontitis"" should keep"_$C(10)
	Set p = p_"   ""Generalised chronic periodontitis"" and ""Localised severe chronic periodontitis""."_$C(10)
	Set p = p_"3. DROP sibling diseases. ""Chronic periodontitis"" must NOT keep ""Aggressive"_$C(10)
	Set p = p_"   periodontitis"" or ""Acute apical periodontitis"" -- same word, different disease."_$C(10)
	Set p = p_"4. DROP broader parents. A question about type 2 diabetes must not become every"_$C(10)
	Set p = p_"   kind of diabetes."_$C(10)
	Set p = p_"5. Every code in ""keep"" must appear verbatim in the candidates. Never invent one."_$C(10)
	Set p = p_"6. Use the question for context. The same word resolves differently depending on"_$C(10)
	Set p = p_"   what else is being asked."_$C(10)
	Set p = p_"7. A DISEASE COHORT includes codes that ENTAIL the diagnosis, not only the code"_$C(10)
	Set p = p_"   that names it. ""Type 2 diabetes"" must keep ""Neuropathy due to type 2 diabetes"_$C(10)
	Set p = p_"   mellitus"" and ""Proteinuria due to type 2 diabetes mellitus"": a patient carrying"_$C(10)
	Set p = p_"   only that code still has type 2 diabetes. Omitting them undercounts the cohort."_$C(10)
	Set p = p_"   This is not the same as rule 4 -- a complication OF the disease entails it, a"_$C(10)
	Set p = p_"   broader PARENT of the disease does not."_$C(10)
	Set p = p_"8. Resolve the clinical concept, not the exact words. A misspelling, an"_$C(10)
	Set p = p_"   abbreviation or a terse phrasing must give the SAME code set as the full"_$C(10)
	Set p = p_"   clinical name. A reported figure must not change because of how it was typed."_$C(10)
	Quit p
}

/// PASS 3 -- SQL. Given the question, the resolved codes and the real projection
/// schema, write the query.
///
/// Codes are supplied as literals, so the model never recalls terminology. The
/// schema is read from INFORMATION_SCHEMA at runtime because FHIR SQL Builder
/// projections are configured per deployment and no two are the same.
ClassMethod SQL() As %String
{
	Set p = "You write a single read-only InterSystems IRIS SQL query."_$C(10,10)
	Set p = p_"You are given: the clinician's question, the table and column schema of this"_$C(10)
	Set p = p_"deployment, and the clinical codes already resolved for each concept."_$C(10,10)
	Set p = p_"Return JSON only:"_$C(10)
	Set p = p_"{""sql"": ""SELECT ..."", ""explanation"": ""one sentence"", ""tables_used"": [""...""]}"_$C(10,10)

	Set p = p_"Rules."_$C(10)
	Set p = p_"1. Use ONLY tables and columns given in the schema. Never guess a name."_$C(10)
	Set p = p_"2. Use the codes you were given, as literals, in an IN (...) list. Do NOT write"_$C(10)
	Set p = p_"   any code that was not supplied, and do NOT match on display text with LIKE --"_$C(10)
	Set p = p_"   the codes are already resolved and text matching reintroduces the ambiguity"_$C(10)
	Set p = p_"   that resolution removed."_$C(10)
	Set p = p_"3. SELECT only. No INSERT, UPDATE, DELETE, DROP, ALTER, CREATE, GRANT or"_$C(10)
	Set p = p_"   procedure calls. A validator rejects the query otherwise."_$C(10)
	Set p = p_"4. Counting patients means COUNT(DISTINCT <patient reference column>), not COUNT(*)."_$C(10)
	Set p = p_"4a. A LIST ""SHOWING WHO HAD X"" IS NOT A LIST OF WHO HAD X. If the question asks"_$C(10)
	Set p = p_"   for a cohort ""showing"" / ""indicating"" / ""with a flag for"" some event, EVERY"_$C(10)
	Set p = p_"   cohort member must appear in the output, and the event becomes a derived"_$C(10)
	Set p = p_"   column:"_$C(10)
	Set p = p_"     SELECT DISTINCT c.PatientId,"_$C(10)
	Set p = p_"            CASE WHEN EXISTS (SELECT 1 FROM <t> o WHERE o.PatientId = c.PatientId"_$C(10)
	Set p = p_"                              AND <event predicate>) THEN 'Yes' ELSE 'No' END AS <Label>"_$C(10)
	Set p = p_"     FROM <t> c WHERE <cohort predicate>"_$C(10)
	Set p = p_"   An inner join to the event instead DROPS everyone the event did not happen to --"_$C(10)
	Set p = p_"   who are usually the exact patients the report exists to find. The result still"_$C(10)
	Set p = p_"   looks plausible, which is what makes it dangerous."_$C(10)
	Set p = p_"5. For ""X after Y"", join the table to itself on PatientId and compare the"_$C(10)
	Set p = p_"   DATE columns in the right direction. For a window (""within N days"") you"_$C(10)
	Set p = p_"   MUST use the real date column the schema names for arithmetic, not the"_$C(10)
	Set p = p_"   ISO-8601 string column: a date function over the string column returns no"_$C(10)
	Set p = p_"   rows at all, so the query answers zero instead of failing."_$C(10)
	Set p = p_"6. IRIS SQL: TOP n not LIMIT n. Use the IRIS date functions available."_$C(10)
	Set p = p_"7. Give EVERY selected expression a readable alias: "_$C(10)
	Set p = p_"   COUNT(DISTINCT PatientId) AS PatientCount, not a bare COUNT(...)."_$C(10)
	Set p = p_"   Without an alias the column comes back named Aggregate_1."_$C(10)
	Set p = p_"8. Keep it one statement, no semicolon, no comments, no markdown fences."_$C(10)
	Quit p
}

/// Render candidate codes for the rerank pass. Compact, because a long concept
/// can expand to over a hundred candidates and the whole list has to fit.
ClassMethod FormatCandidates(phrase As %String, domain As %String, candidates As %DynamicArray) As %String
{
	Set s = "Concept as asked: """_phrase_"""  (expected domain: "_domain_")"_$C(10,10)
	Set s = s_"Candidates:"_$C(10)
	Set it = candidates.%GetIterator()
	While it.%GetNext(.k, .c) {
		If '$IsObject(c) Continue
		Set line = "  "_c.code_"  ["_$Select(c.system'="":c.system, 1:"?")_"]  "_c.display
		If c.inRepository = 0 {
			Set line = line_"   (NOT present in this database)"
		}
		ElseIf c.occurrences '= "" {
			Set line = line_"   ("_c.occurrences_" rows)"
		}
		Set s = s_line_$C(10)
	}
	Quit s
}

}
