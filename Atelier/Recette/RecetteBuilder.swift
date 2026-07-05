// SPDX-License-Identifier: MIT
import Foundation

/// Builds a feature's acceptance test plan ("recette"): deterministic seeds from data the
/// synthesis already has (brief acceptance criteria, findings, coverage, tasks), and renders
/// the items into the vetted, self-contained interactive HTML page. The agent enrichment step
/// (Increment 2) replaces/augments the seeds but reuses this same renderer — the app always
/// owns the page; nothing agent-authored touches the HTML/CSS/JS.
enum RecetteBuilder {

    // MARK: Deterministic seeds

    /// Seeds derived purely from feature data. Always yields at least the smoke + regression
    /// items, so a recette is never empty even for a feature with a thin brief.
    static func deterministicSeeds(brief: BriefDocument?,
                                   taskTitles: [String],
                                   coverage: CoverageReport?,
                                   coverageTarget: Int?,
                                   featureName: String) -> [RecetteItem] {
        var items: [RecetteItem] = []

        items.append(RecetteItem(
            id: "smoke", group: "Prise en main", title: "La feature démarre / se construit",
            priority: .p0, validates: "Bon fonctionnement de base",
            steps: ["Construire / lancer le projet sur la branche d'intégration.",
                    "Ouvrir le point d'entrée touché par la feature."],
            expected: "Ça démarre sans erreur et la feature est accessible.", hint: nil))

        // Acceptance criteria = the definition of done → P0.
        let criteria = brief?.bullets(in: "Acceptance Criteria") ?? []
        for (i, c) in criteria.enumerated() {
            items.append(RecetteItem(
                id: "ac\(i + 1)", group: "Critères d'acceptation", title: "Vérifier : \(shorten(c))",
                priority: .p0, validates: "Critère d'acceptation",
                steps: ["Exercer le comportement décrit par ce critère."],
                expected: c, hint: nil))
        }

        // Build findings = discovered constraints / workarounds → confirm they're acceptable.
        let findings = brief?.bullets(in: "Build Findings") ?? []
        for (i, f) in findings.enumerated() {
            let clean = f.replacingOccurrences(of: "**", with: "")
            items.append(RecetteItem(
                id: "find\(i + 1)", group: "Contraintes & contournements",
                title: "Confirmer : \(shorten(clean))", priority: .p1, validates: "Finding de build",
                steps: ["Relire le contournement (section « Build Findings » du brief)."],
                expected: "Le contournement est acceptable pour cette feature.", hint: clean))
        }

        // Coverage gaps → manually exercise the under-tested paths.
        if let coverage {
            let target = coverageTarget ?? 90
            let below = coverage.belowTarget(target)
            if !below.isEmpty {
                let files = below.prefix(12).map { "\($0.path) — \(Int(($0.rate * 100).rounded()))%" }
                items.append(RecetteItem(
                    id: "cov", group: "Couverture",
                    title: "Tester à la main les zones peu couvertes", priority: .p1,
                    validates: "Couverture < \(target)% (globale \(coverage.percent)%)",
                    steps: ["Exercer manuellement les chemins de ces fichiers :"] + files,
                    expected: "Les chemins non couverts par les tests sont vérifiés à la main.",
                    hint: nil))
            }
        }

        // Tasks built = supporting checks → P2.
        for (i, t) in taskTitles.enumerated() {
            items.append(RecetteItem(
                id: "task\(i + 1)", group: "Tâches livrées", title: "Opérationnel : \(shorten(t))",
                priority: .p2, validates: "Tâche livrée",
                steps: ["Vérifier que cette tâche est intégrée et fonctionne dans la feature."],
                expected: "La tâche est livrée et opérationnelle.", hint: nil))
        }

        items.append(RecetteItem(
            id: "reg", group: "Régression", title: "Rien d'existant n'est cassé",
            priority: .p1, validates: "Non-régression",
            steps: ["Lancer la suite de tests complète.",
                    "Vérifier un parcours adjacent non touché par la feature."],
            expected: "La suite est verte ; aucun comportement existant régressé.", hint: nil))

        return items
    }

    private static func shorten(_ s: String, _ max: Int = 90) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.count <= max ? flat : String(flat.prefix(max - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: Output location

    /// `<projectRoot>/FEATURE-<slug>-recette.html` — next to the deliverable, committable.
    static func recetteURL(projectPath: String, featureName: String) -> URL {
        URL(fileURLWithPath: projectPath)
            .appendingPathComponent("FEATURE-\(BacklogMD.slugify(featureName))-recette.html")
    }

    @discardableResult
    static func write(featureName: String, projectName: String, projectPath: String,
                      items: [RecetteItem], generatedNote: String) throws -> URL {
        let url = recetteURL(projectPath: projectPath, featureName: featureName)
        let html = renderHTML(featureName: featureName, projectName: projectName,
                              items: items, generatedNote: generatedNote)
        try html.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: Render (vetted template — all item text is HTML-escaped)

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func renderHTML(featureName: String, projectName: String,
                           items: [RecetteItem], generatedNote: String) -> String {
        // Groups in first-appearance order; within a group, sort by priority (P0 first, stable).
        var groupOrder: [String] = []
        for it in items where !groupOrder.contains(it.group) { groupOrder.append(it.group) }

        var sectionsHTML = ""
        for (gi, group) in groupOrder.enumerated() {
            let groupItems = items.enumerated()
                .filter { $0.element.group == group }
                .sorted { ($0.element.priority.rank, $0.offset) < ($1.element.priority.rank, $1.offset) }
                .map { $0.element }
            sectionsHTML += """
            <section>
              <div class="sec-head"><span class="sec-num">\(String(format: "%02d", gi + 1))</span><h2>\(esc(group))</h2></div>
            \(groupItems.map(card).joined(separator: "\n"))
            </section>

            """
        }

        let p0total = items.filter { $0.priority == .p0 }.count
        return template(featureName: esc(featureName), projectName: esc(projectName),
                        generatedNote: esc(generatedNote), total: items.count,
                        p0total: p0total, sectionsHTML: sectionsHTML)
    }

    private static func card(_ it: RecetteItem) -> String {
        let steps = it.steps.map { "        <li>\(esc($0))</li>" }.joined(separator: "\n")
        let hint = it.hint.map {
            "\n        <div class=\"hint\"><span class=\"lbl\">Note</span> \(esc($0))</div>"
        } ?? ""
        return """
          <article class="test" data-id="\(esc(it.id))" data-prio="\(it.priority.label)">
            <div class="thead"><span class="chk" tabindex="0" role="checkbox" aria-checked="false"><svg viewBox="0 0 16 16" fill="none"><path d="M3 8.5l3.2 3L13 4.5" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/></svg></span>
              <div class="titles"><div class="tid">\(esc(it.id.uppercased()))</div><div class="ttitle">\(esc(it.title))</div>
                <div class="validates">Valide : <b>\(esc(it.validates))</b></div></div>
              <span class="prio \(it.priority.rawValue)">\(it.priority.label)</span></div>
            <div class="tbody">
              <ol class="steps">
        \(steps)
              </ol>
              <div class="expect"><span class="lbl">Attendu</span>\(esc(it.expected))</div>\(hint)
            </div>
          </article>
        """
    }

    // The self-contained page: CSS + interactive JS (checkboxes, progress, P0 filter, localStorage).
    private static func template(featureName: String, projectName: String, generatedNote: String,
                                 total: Int, p0total: Int, sectionsHTML: String) -> String {
        """
        <!doctype html><html lang="fr"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Recette — \(featureName)</title>
        <style>
        :root{--paper:#F1EFE8;--card:#FBFAF6;--ink:#23211C;--ink2:#6C665B;--ink3:#948F82;
        --line:#DED9CC;--line2:#EAE6DB;--accent:#0E5A54;--p0:#AC382B;--p0bg:#F5E1DD;
        --p1:#976911;--p1bg:#F2E7CC;--p2:#4C6C5D;--p2bg:#E3E9E3;--done:#2E7D53;--donebg:#E7F1EA;
        --mono:ui-monospace,"SF Mono",Menlo,Consolas,monospace;--sans:ui-sans-serif,-apple-system,"SF Pro Text","Segoe UI",sans-serif;}
        *{box-sizing:border-box;}
        body{margin:0;background:var(--paper);color:var(--ink);font-family:var(--sans);font-size:15px;line-height:1.6;-webkit-font-smoothing:antialiased;}
        .wrap{max-width:860px;margin:0 auto;padding:0 22px 120px;}
        header{position:sticky;top:0;z-index:20;background:rgba(241,239,232,.92);backdrop-filter:saturate(1.4) blur(8px);border-bottom:1px solid var(--line);margin:0 -22px 28px;padding:14px 22px;}
        .hbar{max-width:860px;margin:0 auto;display:flex;align-items:center;gap:16px;flex-wrap:wrap;}
        .brand{display:flex;flex-direction:column;gap:1px;margin-right:auto;}
        .brand .eyebrow{font-family:var(--mono);font-size:11px;letter-spacing:.14em;text-transform:uppercase;color:var(--accent);}
        .brand strong{font-size:15px;font-weight:650;letter-spacing:-.01em;}
        .meter{display:flex;align-items:center;gap:10px;}
        .meter .nums{font-family:var(--mono);font-size:13px;font-variant-numeric:tabular-nums;color:var(--ink2);white-space:nowrap;}
        .meter .nums b{color:var(--ink);}
        .track{width:150px;height:7px;border-radius:99px;background:var(--line);overflow:hidden;}
        .fill{height:100%;width:0%;background:var(--accent);transition:width .35s ease;}
        button.tool{font-family:var(--mono);font-size:11.5px;letter-spacing:.03em;text-transform:uppercase;color:var(--ink2);background:var(--card);border:1px solid var(--line);border-radius:7px;padding:6px 10px;cursor:pointer;}
        button.tool:hover{border-color:var(--accent);color:var(--accent);}
        button.tool[aria-pressed="true"]{background:var(--accent);color:#fff;border-color:var(--accent);}
        button.tool:focus-visible,.chk:focus-visible{outline:2px solid var(--accent);outline-offset:2px;}
        .hero{padding:12px 0 4px;}
        h1{font-size:27px;line-height:1.14;letter-spacing:-.02em;margin:0 0 8px;text-wrap:balance;}
        .lede{font-size:15px;color:var(--ink2);max-width:64ch;margin:0;}
        .legend{display:flex;gap:16px;flex-wrap:wrap;margin:16px 0 4px;padding:11px 0;border-top:1px solid var(--line2);border-bottom:1px solid var(--line2);font-size:13px;color:var(--ink2);}
        .legend span{display:inline-flex;align-items:center;gap:7px;}
        section{margin-top:34px;scroll-margin-top:88px;}
        .sec-head{display:flex;align-items:baseline;gap:12px;margin:0 0 8px;}
        .sec-num{font-family:var(--mono);font-size:13px;color:var(--accent);font-weight:600;}
        .sec-head h2{font-size:21px;letter-spacing:-.015em;margin:0;}
        .test{background:var(--card);border:1px solid var(--line);border-radius:11px;margin:12px 0;overflow:hidden;}
        .test.done{background:var(--donebg);border-color:#CDE3D6;}
        .thead{display:flex;gap:13px;align-items:flex-start;padding:15px 18px;cursor:pointer;}
        .chk{flex:0 0 auto;width:22px;height:22px;border-radius:6px;border:1.5px solid var(--line);background:#fff;display:grid;place-items:center;margin-top:1px;cursor:pointer;transition:.15s;}
        .chk svg{width:13px;height:13px;opacity:0;transform:scale(.6);transition:.15s;color:#fff;}
        .test.done .chk{background:var(--done);border-color:var(--done);}
        .test.done .chk svg{opacity:1;transform:scale(1);}
        .titles{flex:1 1 auto;min-width:0;}
        .tid{font-family:var(--mono);font-size:11px;letter-spacing:.06em;color:var(--ink3);}
        .ttitle{font-size:16px;font-weight:600;letter-spacing:-.01em;margin:1px 0 0;line-height:1.3;}
        .test.done .ttitle{color:var(--ink2);}
        .validates{font-size:12.5px;color:var(--ink2);margin-top:5px;}
        .validates b{color:var(--accent);font-weight:600;}
        .prio{flex:0 0 auto;font-family:var(--mono);font-size:11px;font-weight:600;letter-spacing:.05em;padding:3px 8px;border-radius:6px;height:fit-content;}
        .p0{color:var(--p0);background:var(--p0bg);}.p1{color:var(--p1);background:var(--p1bg);}.p2{color:var(--p2);background:var(--p2bg);}
        .tbody{padding:0 18px 18px 53px;}
        ol.steps{margin:2px 0 0;padding-left:20px;}ol.steps li{margin:5px 0;}
        .expect{margin-top:12px;padding:10px 14px;background:#fff;border:1px solid var(--line);border-left:3px solid var(--accent);border-radius:7px;font-size:14px;}
        .expect .lbl{font-family:var(--mono);font-size:10.5px;letter-spacing:.1em;text-transform:uppercase;color:var(--accent);display:block;margin-bottom:3px;}
        .hint{margin-top:10px;font-size:13px;color:var(--ink2);}
        .hint .lbl{font-family:var(--mono);font-size:10.5px;letter-spacing:.08em;text-transform:uppercase;color:var(--ink3);}
        .hidden{display:none!important;}
        footer{margin-top:44px;padding-top:16px;border-top:1px solid var(--line2);font-size:12.5px;color:var(--ink3);}
        @media (prefers-reduced-motion:reduce){*{transition:none!important;}}
        @media print{header{position:static;}button.tool{display:none;}.test{break-inside:avoid;}}
        </style></head><body>
        <header><div class="hbar">
          <div class="brand"><span class="eyebrow">Recette · validation</span><strong>\(projectName) — \(featureName)</strong></div>
          <div class="meter"><div class="track"><div class="fill" id="fill"></div></div>
            <div class="nums"><b id="doneCount">0</b>/<span id="total">\(total)</span> · P0 <b id="p0done">0</b>/<span id="p0total">\(p0total)</span></div></div>
          <div style="display:flex;gap:8px"><button class="tool" id="p0btn" aria-pressed="false">P0 only</button><button class="tool" id="resetbtn">Reset</button></div>
        </div></header>
        <div class="wrap">
          <div class="hero">
            <h1>Recette — \(featureName)</h1>
            <p class="lede">Ce qu'il faut vérifier pour valider la feature qu'Atelier vient de livrer. Commence par les <b>P0</b> (les critères d'acceptation). Progression sauvegardée dans ce navigateur.</p>
            <div class="legend">
              <span><span class="prio p0">P0</span> critère d'acceptation / bloquant</span>
              <span><span class="prio p1">P1</span> important</span>
              <span><span class="prio p2">P2</span> support</span>
            </div>
          </div>
        \(sectionsHTML)
          <footer>\(generatedNote)</footer>
        </div>
        <script>
        (function(){
          var KEY="atelier-recette-"+document.title;var state={};
          try{state=JSON.parse(localStorage.getItem(KEY)||"{}");}catch(e){state={};}
          var tests=[].slice.call(document.querySelectorAll(".test"));
          var fill=document.getElementById("fill"),doneCount=document.getElementById("doneCount"),p0done=document.getElementById("p0done");
          function persist(){try{localStorage.setItem(KEY,JSON.stringify(state));}catch(e){}}
          function render(){var d=0,p=0;tests.forEach(function(t){var on=!!state[t.dataset.id];t.classList.toggle("done",on);var b=t.querySelector(".chk");if(b)b.setAttribute("aria-checked",on?"true":"false");if(on){d++;if(t.dataset.prio==="P0")p++;}});doneCount.textContent=d;p0done.textContent=p;fill.style.width=(tests.length?d/tests.length*100:0)+"%";}
          function toggle(t){state[t.dataset.id]=!state[t.dataset.id];persist();render();}
          tests.forEach(function(t){t.querySelector(".thead").addEventListener("click",function(){toggle(t);});var b=t.querySelector(".chk");if(b)b.addEventListener("keydown",function(e){if(e.key===" "||e.key==="Enter"){e.preventDefault();e.stopPropagation();toggle(t);}});});
          var p0btn=document.getElementById("p0btn");
          p0btn.addEventListener("click",function(){var on=p0btn.getAttribute("aria-pressed")==="true";p0btn.setAttribute("aria-pressed",(!on).toString());tests.forEach(function(t){t.classList.toggle("hidden",!on&&t.dataset.prio!=="P0");});});
          document.getElementById("resetbtn").addEventListener("click",function(){if(confirm("Décocher tous les tests ?")){state={};persist();render();}});
          render();
        })();
        </script>
        </body></html>
        """
    }
}
