/// One-shot environment setup. Idempotent: safe to re-run.
///
/// Written as a class method rather than a terminal script because multi-line
/// control flow does not survive being piped line-by-line into `iris session`.
///
///   docker exec fhirsqlllm iris session IRIS -U %SYS \
///     "##class(INT.FHIRSQLLLM.Setup.Installer).Run()"
Class INT.FHIRSQLLLM.Setup.Installer
{

Parameter NAMESPACE = "FHIRSQLLLM";

Parameter SSLCONFIG = "LLMClient";

Parameter FHIRAPP = "/fhir/r4";

Parameter SRCDIR = "/home/irisowner/src";

ClassMethod Run(skipFHIR As %Boolean = 0) As %Status
{
	Set ns = ..#NAMESPACE
	Write !,"=== INT.FHIRSQLLLM setup ===",!
	Do ..SSLClient()
	Do ..Namespace(ns)
	Do ..Interop(ns)
	If 'skipFHIR Do ..FHIRServer(ns)
	Do ..ImportSource(ns)
	Write !,"--- done ---",!
	Write "Portal        : http://localhost:52773/csp/sys/UtilHome.csp",!
	Write "FHIR metadata : http://localhost:52773",..#FHIRAPP,"/metadata",!
	Write "Namespace     : ",ns,!
	Quit $$$OK
}

/// Outbound HTTPS client config. No certificate or key files are needed because
/// we are only ever the client. VerifyPeer = 0 means no MITM protection, which
/// is acceptable for a demo but must be 1 with a real CA for anything on PHI.
ClassMethod SSLClient() As %Status
{
	New $Namespace
	Set $Namespace = "%SYS"
	Set name = ..#SSLCONFIG
	If ##class(Security.SSLConfigs).Exists(name) {
		Write "SSL/TLS '",name,"' already exists",!
		Quit $$$OK
	}
	Set p("Enabled") = 1
	Set p("Type") = 0
	Set p("VerifyPeer") = 0
	Set p("Description") = "Outbound HTTPS: LLM APIs, FHIR terminology, RxNav"
	Set sc = ##class(Security.SSLConfigs).Create(name, .p)
	If $$$ISERR(sc) {
		Write "SSL/TLS create failed, retrying with defaults: ",$System.Status.GetErrorText(sc),!
		Set sc = ##class(Security.SSLConfigs).Create(name)
	}
	Write "SSL/TLS '",name,"': ",$Select($$$ISOK(sc):"created",1:$System.Status.GetErrorText(sc)),!
	Quit sc
}

/// Create the database FILE, register it, then create the namespace.
///
/// Config.Databases.Create() only writes the configuration entry -- it does not
/// create IRIS.DAT. Without SYS.Database.CreateDatabase() first, switching into
/// the namespace fails with <DIRECTORY>.
///
/// The directory sits under the instance's mgr folder, matching where the
/// shipped databases live (/durable/irissys/mgr/HSCUSTOM/IRIS.DAT etc.).
ClassMethod Namespace(ns As %String) As %Status
{
	New $Namespace
	Set $Namespace = "%SYS"
	Set dir = "/durable/irissys/mgr/"_ns

	// 1. the directory
	If '##class(%File).DirectoryExists(dir) {
		Do ##class(%File).CreateDirectoryChain(dir)
		Write "created directory ",dir,!
	}

	// 2. the database file -- this is the step that was missing
	If '##class(%File).Exists(dir_"/IRIS.DAT") {
		Write "creating database file in ",dir," ...",!
		Set sc = ##class(SYS.Database).CreateDatabase(dir)
		If $$$ISERR(sc) {
			Write "  CreateDatabase failed: ",$System.Status.GetErrorText(sc),!
			Quit sc
		}
		Write "  IRIS.DAT created",!
	}

	// 3. register the database in the configuration
	If '##class(Config.Databases).Exists(ns) {
		Set dbProps("Directory") = dir
		Set sc = ##class(Config.Databases).Create(ns, .dbProps)
		If $$$ISERR(sc) {
			Write "  Databases.Create failed: ",$System.Status.GetErrorText(sc),!
			Quit sc
		}
		Write "  database ",ns," registered",!
	}

	// 4. the namespace, pointing globals and routines at it
	If ##class(Config.Namespaces).Exists(ns) {
		Write "namespace ",ns," already configured",!
		Quit $$$OK
	}
	Set nsProps("Globals") = ns
	Set nsProps("Routines") = ns
	Set sc = ##class(Config.Namespaces).Create(ns, .nsProps)
	Write "namespace ",ns,": ",$Select($$$ISOK(sc):"created",1:$System.Status.GetErrorText(sc)),!
	Quit sc
}

/// Interoperability must be enabled before Ens.* classes resolve in the namespace.
ClassMethod Interop(ns As %String) As %Status
{
	New $Namespace
	Set $Namespace = ns
	If ##class(%Library.EnsembleMgr).IsEnsembleNamespace(ns) {
		Write "interoperability already enabled in ",ns,!
		Quit $$$OK
	}
	Write "enabling interoperability in ",ns," ...",!
	Set sc = ##class(%Library.EnsembleMgr).EnableNamespace(ns, 1)
	Write "  ",$Select($$$ISOK(sc):"enabled",1:$System.Status.GetErrorText(sc)),!
	Quit sc
}

/// Install the FHIR R4 server and endpoint.
///
/// API notes for IRIS for Health 2026.1, all learned the hard way:
///   * CreateEndpoint() does not exist. It is InstallInstance(appKey, strategy, packages).
///   * InstallInstance is a PROCEDURE -- `set sc = ...` raises <COMMAND>.
///   * HS.FHIRServer.ServiceRegistry does not exist. Query HS_FHIRServer.RepoInstance.
///   * Errors are NOT swallowed here. A silent catch previously reported success
///     while the endpoint was never created, which cost two debug cycles.
ClassMethod FHIRServer(ns As %String) As %Status
{
	New $Namespace
	Set $Namespace = ns
	If '##class(%Dictionary.CompiledClass).%ExistsId("HS.FHIRServer.Installer") {
		Write "!! HS.FHIRServer.Installer not present -- is this IRIS for Health?",!
		Quit $$$ERROR($$$GeneralError, "FHIR server classes absent; wrong image?")
	}
	Set app = ..#FHIRAPP
	If ..EndpointExists(app) {
		Write "FHIR endpoint ",app," already exists",!
		Quit $$$OK
	}
	Write "installing FHIR R4 server into ",ns," (takes a few minutes) ...",!
	Set tSC = $$$OK
	Try {
		Do ##class(HS.FHIRServer.Installer).InstallNamespace()
		Do ##class(HS.FHIRServer.Installer).InstallInstance(
			app,
			"HS.FHIRServer.Storage.Json.InteractionsStrategy",
			$ListBuild("hl7.fhir.r4.core@4.0.1"))
	}
	Catch e {
		Set tSC = e.AsStatus()
		Write "  FHIR install raised: ",e.DisplayString(),!
	}
	If ..EndpointExists(app) {
		Write "  endpoint ready: ",app,!
		Quit $$$OK
	}
	Write "  !! endpoint ",app," was NOT created",!
	Quit $Select($$$ISERR(tSC): tSC, 1: $$$ERROR($$$GeneralError, "FHIR endpoint not created: "_app))
}

/// There is no ServiceRegistry class in 2026.1; the endpoint lives in a table.
ClassMethod EndpointExists(app As %String) As %Boolean
{
	Set found = 0
	Try {
		Set rs = ##class(%SQL.Statement).%ExecDirect(,
			"SELECT COUNT(*) AS N FROM HS_FHIRServer.RepoInstance WHERE cspUrl = ?", app)
		If rs.%Next() Set found = (+rs.%Get("N") > 0)
	} Catch { Set found = 0 }
	Quit found
}

/// Load FHIR resource files into the endpoint.
///
/// pServiceType accepts only "FHIRSERVER" or "HTTP" (case-insensitive) -- NOT a
/// class name. Passing anything else makes every worker job throw
/// InvalidServiceTypeSpecified into messages.log while the API returns quietly,
/// so the load looks like it started and writes zero rows.
///
/// The call is asynchronous: it queues worker jobs and returns immediately.
ClassMethod LoadResources(dir As %String = "/tmp/load", app As %String = {..#FHIRAPP}) As %Status
{
	New $Namespace
	Set $Namespace = ..#NAMESPACE
	If '..EndpointExists(app) {
		Quit $$$ERROR($$$GeneralError, "no FHIR endpoint at "_app_"; run FHIRServer() first")
	}
	Write "submitting ",dir," to ",app," (asynchronous) ...",!
	Do ##class(HS.FHIRServer.Tools.DataLoader).SubmitResourceFiles(dir, "FHIRSERVER", app)
	Quit $$$OK
}

/// Resource counts actually present, for verifying a load.
ClassMethod Counts() As %Status
{
	New $Namespace
	Set $Namespace = ..#NAMESPACE
	Set rs = ##class(%SQL.Statement).%ExecDirect(,
		"SELECT ResourceType, COUNT(*) AS N FROM HSFHIR_X0001_R.Rsrc "_
		"GROUP BY ResourceType ORDER BY 2 DESC")
	Set total = 0
	While rs.%Next() {
		Write $Justify(rs.%Get("N"), 9), "  ", rs.%Get("ResourceType"), !
		Set total = total + rs.%Get("N")
	}
	Write $Justify(total, 9), "  TOTAL", !
	Quit $$$OK
}

/// Import into the target namespace, where Ens.* and EnsLib.* resolve.
ClassMethod ImportSource(ns As %String) As %Status
{
	New $Namespace
	Set $Namespace = ns
	Write !,"importing source from ",..#SRCDIR," into ",ns,!
	Set sc = $System.OBJ.LoadDir(..#SRCDIR, "ck", , 1)
	Write "  ",$Select($$$ISOK(sc):"ok",1:$System.Status.GetErrorText(sc)),!
	Quit sc
}

}
