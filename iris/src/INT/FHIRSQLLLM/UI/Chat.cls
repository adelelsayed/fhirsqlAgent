/// The chat page. Ask a clinical question, see the SQL, the rows, and -- the
/// point of the design -- which codes were chosen and why.
///
/// Served at /csp/healthshare/fhirsqlllm/INT.FHIRSQLLLM.UI.Chat.cls
///
/// The resolution panel is not decoration. A clinician cannot audit a SELECT
/// statement, but they can audit "we counted these three codes as chronic
/// periodontitis and excluded asymptomatic periapical periodontitis". That is
/// the reviewable artifact.
Class INT.FHIRSQLLLM.UI.Chat Extends %CSP.Page
{

Parameter CONTENTTYPE = "text/html";

Parameter PRIVATE = 0;

ClassMethod OnPage() As %Status
{
	// The ask action is answered here, not in OnPreHTTP. OnPreHTTP runs before
	// the response headers are flushed, so anything Written there is discarded --
	// returning 0 from it skipped OnPage and sent an EMPTY body, which the page's
	// fetch() reported as "Unexpected end of JSON input". OnPreHTTP now only sets
	// the content type and lets OnPage run.
	If $Get(%request.Data("ACTION", 1)) = "ask" {
		Do ..WriteJSON()
		Quit $$$OK
	}

	&html<<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>FHIR SQL Agent</title>
<style>
:root{
  --bg:#f7f8fa; --panel:#fff; --ink:#1b2230; --muted:#6b7585;
  --line:#e3e7ee; --accent:#1f6f8b; --keep:#1d7a4d; --drop:#a33a2a;
  --code:#f2f4f8;
}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);
  font:15px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
.wrap{max-width:1040px;margin:0 auto;padding:24px 16px 64px}
h1{font-size:20px;margin:0 0 2px;letter-spacing:-.01em}
.sub{color:var(--muted);font-size:13px;margin:0 0 20px}
.ask{display:flex;gap:8px;margin-bottom:8px}
.ask input{flex:1;padding:11px 13px;border:1px solid var(--line);border-radius:8px;
  font-size:15px;background:var(--panel)}
.ask input:focus{outline:2px solid var(--accent);outline-offset:-1px}
.ask button{padding:11px 18px;border:0;border-radius:8px;background:var(--accent);
  color:#fff;font-size:15px;font-weight:500;cursor:pointer}
.ask button:disabled{opacity:.5;cursor:default}
.eg{font-size:13px;color:var(--muted);margin-bottom:22px}
.eg a{color:var(--accent);text-decoration:none;margin-right:14px;cursor:pointer}
.eg a:hover{text-decoration:underline}
.card{background:var(--panel);border:1px solid var(--line);border-radius:10px;
  padding:16px 18px;margin-bottom:14px}
.card h2{font-size:12px;text-transform:uppercase;letter-spacing:.06em;
  color:var(--muted);margin:0 0 10px;font-weight:600}
pre{background:var(--code);border-radius:7px;padding:12px;overflow-x:auto;
  font:13px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace;margin:0;
  white-space:pre-wrap;word-break:break-word}
table{border-collapse:collapse;width:100%;font-size:13.5px}
th,td{text-align:left;padding:6px 10px;border-bottom:1px solid var(--line)}
th{color:var(--muted);font-weight:600;font-size:12px;text-transform:uppercase;
  letter-spacing:.04em}
.ent{border-left:3px solid var(--line);padding:2px 0 2px 12px;margin-bottom:14px}
.ent .ph{font-weight:600}
.ent .dm{color:var(--muted);font-size:13px;margin-left:6px}
.code{font:12.5px ui-monospace,Menlo,monospace;padding:1px 5px;border-radius:4px;
  background:var(--code)}
.k{color:var(--keep)} .d{color:var(--drop)}
.why{color:var(--muted);font-size:13px}
.meta{color:var(--muted);font-size:12.5px;display:flex;gap:16px;flex-wrap:wrap}
.err{background:#fdf2f0;border-color:#f0cfc8;color:var(--drop)}
.spin{color:var(--muted);font-size:14px}
@media (prefers-color-scheme:dark){
  :root{--bg:#141820;--panel:#1b202a;--ink:#e6e9ef;--muted:#8e99ab;
    --line:#2a313e;--code:#222835;--accent:#4a9db8;--keep:#4cc08a;--drop:#e08273}
}
</style></head><body><div class="wrap">
<h1>FHIR SQL Agent</h1>
<p class="sub">Terminology is resolved through the SNOMED hierarchy, not recalled by the model.</p>

<div class="ask">
  <input id="q" placeholder="How many patients have chronic periodontitis?" autofocus>
  <button id="go" onclick="ask()">Ask</button>
</div>
<div class="eg">Try:
  <a onclick="setq(this)">How many patients have chronic periodontitis?</a>
  <a onclick="setq(this)">How many patients were diagnosed with viral sinusitis?</a>
  <a onclick="setq(this)">List patients with a gingivitis diagnosis</a>
</div>

<div id="out"></div>

<script>
function setq(a){document.getElementById('q').value=a.textContent;ask()}
function esc(s){return String(s==null?'':s).replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]))}
document.getElementById('q').addEventListener('keydown',e=>{if(e.key==='Enter')ask()});

async function ask(){
  const q=document.getElementById('q').value.trim(); if(!q)return;
  const out=document.getElementById('out'), btn=document.getElementById('go');
  btn.disabled=true;
  out.innerHTML='<div class="card"><span class="spin">resolving terminology and composing SQL&hellip;</span></div>';
  try{
    const r=await fetch('INT.FHIRSQLLLM.UI.Chat.cls?ACTION=ask',{
      method:'POST',headers:{'Content-Type':'application/json'},
      body:JSON.stringify({question:q})});
    const d=await r.json();
    out.innerHTML=render(d);
  }catch(e){
    out.innerHTML='<div class="card err"><h2>Request failed</h2><pre>'+esc(e)+'</pre></div>';
  }
  btn.disabled=false;
}

function render(d){
  let h='';
  if(d.error) h+='<div class="card err"><h2>Error</h2><pre>'+esc(d.error)+'</pre></div>';
  if(d.summary) h+='<div class="card"><h2>Answer</h2><div>'+esc(d.summary)+'</div></div>';

  // resolution first: it is the reviewable part
  if(d.resolution && d.resolution.length){
    h+='<div class="card"><h2>Terminology resolution</h2>';
    for(const e of d.resolution){
      h+='<div class="ent"><div><span class="ph">'+esc(e.phrase)+'</span>';
      if(e.domain) h+='<span class="dm">'+esc(e.domain)+'</span>';
      if(e.confidence) h+='<span class="dm">confidence '+esc(e.confidence)+'</span>';
      h+='</div>';
      for(const k of (e.kept||[]))
        h+='<div class="k">&#10003; <span class="code">'+esc(k.code)+'</span> '+esc(k.display)+
           (k.why?' <span class="why">&mdash; '+esc(k.why)+'</span>':'')+'</div>';
      for(const k of (e.dropped||[]))
        h+='<div class="d">&#10007; <span class="code">'+esc(k.code)+'</span>'+
           (k.why?' <span class="why">&mdash; '+esc(k.why)+'</span>':'')+'</div>';
      if(e.note) h+='<div class="why">note: '+esc(e.note)+'</div>';
      h+='</div>';
    }
    h+='</div>';
  }

  if(d.sql) h+='<div class="card"><h2>SQL</h2><pre>'+esc(d.sql)+'</pre></div>';

  if(d.rows && d.rows.length){
    const cols=Object.keys(d.rows[0]);
    h+='<div class="card"><h2>Rows ('+d.rowCount+')</h2><div style="overflow-x:auto"><table><tr>';
    for(const c of cols) h+='<th>'+esc(c)+'</th>';
    h+='</tr>';
    for(const r of d.rows.slice(0,50)){
      h+='<tr>'; for(const c of cols) h+='<td>'+esc(r[c])+'</td>'; h+='</tr>';
    }
    h+='</table></div></div>';
  }

  h+='<div class="card"><h2>Trace</h2><div class="meta">';
  if(d.models) h+='<span>models: '+esc(d.models)+'</span>';
  if(d.totalMs!=null) h+='<span>'+esc(d.totalMs)+' ms</span>';
  if(d.sessionId) h+='<span>session '+esc(d.sessionId)+'</span>';
  h+='</div></div>';
  return h;
}
</script>
</div></body></html>>
	Quit $$$OK
}

/// Set the response content type for the ask action, then let OnPage run.
///
/// This must return 1. Returning 0 tells CSP to skip OnPage, and the body has
/// to be written from OnPage -- see the note there.
ClassMethod OnPreHTTP() As %Boolean [ ServerOnly = 1 ]
{
	If $Get(%request.Data("ACTION", 1)) = "ask" {
		Set %response.ContentType = "application/json"
		Set %response.CharSet = "utf-8"
	}
	Quit 1
}

/// Run one question and write the page's JSON reply.
///
/// Always writes a parseable object, including on failure: the page does
/// response.json() unconditionally, so an empty body is a client-side crash
/// rather than an error message the user can read.
ClassMethod WriteJSON() As %Status
{
	Set out = {}
	Try {
		Set body = %request.Content
		If $IsObject(body) {
			Do body.Rewind()
			Set payload = {}.%FromJSON(body)
		}
		Else {
			Set payload = {}.%FromJSON(body)
		}
		Set q = payload.question
		If q = "" {
			Set out.error = "no question supplied"
		}
		Else {
			Do ..RunAgent(q, .out)
		}
	}
	Catch e {
		Set out.error = e.DisplayString()
	}

	Set json = ""
	Try { Set json = out.%ToJSON() } Catch {}
	If json = "" {
		Set json = "{""error"":""the reply could not be serialised; see the message trace""}"
	}
	Write json
	Quit $$$OK
}

/// Send the question through the production and shape the reply for the page.
ClassMethod RunAgent(question As %String, Output out As %DynamicObject) As %Status
{
	Set out = {}

	// through the real inbound business service, so the trace has a genuine origin:
	// the service builds the Question, stamps the TurnId, and hands it to the
	// orchestrator, exactly as any other inbound channel would
	Set rsp = ##class(INT.FHIRSQLLLM.Agent.Service).Ask(question, 0, .err, .sessionId)
	Set out.sessionId = sessionId
	If '$IsObject(rsp) {
		Set out.error = err
		Quit $$$OK
	}

	Set out.summary = rsp.Summary
	Set out.models = rsp.ModelsUsed
	Set out.totalMs = rsp.TotalMs
	Set out.rowCount = rsp.RowCount
	Set out.answerable = rsp.Answerable
	If rsp.Error '= "" Set out.error = rsp.Error
	Set out.sql = ##class(INT.FHIRSQLLLM.Agent.Answer).StreamText(rsp.SQL)

	Set rtext = ##class(INT.FHIRSQLLLM.Agent.Answer).StreamText(rsp.Resolution)
	If rtext '= "" {
		Try { Set out.resolution = [].%FromJSON(rtext) } Catch { }
	}
	Set rowtext = ##class(INT.FHIRSQLLLM.Agent.Answer).StreamText(rsp.Rows)
	If rowtext '= "" {
		Try { Set out.rows = [].%FromJSON(rowtext) } Catch { }
	}
	Quit $$$OK
}

}
