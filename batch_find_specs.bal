import ballerina/io;
import ballerina/os;
import ballerina/time;

// ─────────────────────────────────────────────────────────────────────────────
// TYPES
// ─────────────────────────────────────────────────────────────────────────────

type ApiEntry record {
    string name;
    string docs_url;
    int check_frequency_days;
    string? target_spec = ();
};

type ResultEntry record {
    string name;
    string docs_url;
    string? target_spec;
    string? spec_url;
    string? version;
    string? format;
    string? title;
    string status;          // "found" | "not_found" | "skipped"
    boolean is_new_version;
    int check_frequency_days;
    string? found_at;
};

// ─────────────────────────────────────────────────────────────────────────────
// API LIST
// ─────────────────────────────────────────────────────────────────────────────

final ApiEntry[] API_DOCS = [
    // ── Previously failing / mentioned in review ──────────────────────────────
    {
        name: "Asana",
        docs_url: "https://developers.asana.com/reference/rest-api-reference",
        check_frequency_days: 7
    },
    {
        name: "GitHub",
        docs_url: "https://docs.github.com/en/rest",
        check_frequency_days: 7
    },
    {
        name: "DocuSign Admin API",
        docs_url: "https://developers.docusign.com/docs/admin-api/",
        check_frequency_days: 30
    },
    {
        name: "DocuSign Click API",
        docs_url: "https://developers.docusign.com/docs/click-api/",
        check_frequency_days: 30
    },
    {
        name: "DocuSign eSign API",
        docs_url: "https://developers.docusign.com/docs/esign-rest-api/",
        check_frequency_days: 30
    },

    // ── Candid: 3 specific specs from one docs URL ────────────────────────────
    {
        name: "Candid CharityCheckPdf",
        docs_url: "https://developer.candid.org/reference/openapi",
        check_frequency_days: 30,
        target_spec: "CharityCheckPdf"
    },
    {
        name: "Candid Essentials",
        docs_url: "https://developer.candid.org/reference/openapi",
        check_frequency_days: 30,
        target_spec: "Essentials"
    },
    {
        name: "Candid Premier",
        docs_url: "https://developer.candid.org/reference/openapi",
        check_frequency_days: 30,
        target_spec: "Premier API"
    },

    // ── New APIs from ballerinax modules ──────────────────────────────────────
    {
        name: "Discord",
        docs_url: "https://discord.com/developers/docs/reference",
        check_frequency_days: 7
    }
];

// ─────────────────────────────────────────────────────────────────────────────
// SKIP LOGIC
// TODO: Enable frequency-skipping once tested.
// Currently always returns false — every API always runs.
// ─────────────────────────────────────────────────────────────────────────────

function shouldSkip(ApiEntry api) returns boolean {
    // Uncomment to activate frequency-skipping:
    //
    // MemoryEntry? entry = getMemoryEntry(api.docs_url);
    // if entry is MemoryEntry && entry.last_searched is string {
    //     time:Utc last = check time:utcFromString(entry.last_searched ?: "");
    //     time:Utc now = time:utcNow();
    //     decimal elapsedSecs = time:utcDiffSeconds(now, last);
    //     int elapsedDays = <int>(elapsedSecs / 86400.0);
    //     if elapsedDays < api.check_frequency_days {
    //         io:println(string `  [skip] ${api.name}: checked ${elapsedDays}d ago, frequency=${api.check_frequency_days}d`);
    //         return true;
    //     }
    // }
    return false;
}

function repeatString(string value, int count) returns string {
    string out = "";
    int i = 0;
    while i < count {
        out += value;
        i += 1;
    }
    return out;
}

// ─────────────────────────────────────────────────────────────────────────────
// BATCH RUNNER
// ─────────────────────────────────────────────────────────────────────────────

function batchFindSpecs(string outputFile = "openapi_specs.json") returns error? {
    string? apiKey = os:getEnv("ANTHROPIC_API_KEY");
    if apiKey is () || apiKey == "" {
        return error("Set ANTHROPIC_API_KEY environment variable");
    }

    OpenAPIAgent agent = check new (apiKey);
    ResultEntry[] results = [];

    foreach ApiEntry api in API_DOCS {
        io:println(string `\n${repeatString("=", 70)}`);
        io:println(string `Processing  : ${api.name}`);
        io:println(string `Docs URL    : ${api.docs_url}`);
        if api.target_spec is string {
            io:println(string `Target spec : ${api.target_spec ?: ""}`);
        }
        io:println(string `Frequency   : every ${api.check_frequency_days} day(s)  [skip inactive]`);
        io:println(repeatString("=", 70));

        if shouldSkip(api) {
            results.push({
                name: api.name,
                docs_url: api.docs_url,
                target_spec: api.target_spec,
                spec_url: (),
                version: (),
                format: (),
                title: (),
                status: "skipped",
                is_new_version: false,
                check_frequency_days: api.check_frequency_days,
                found_at: ()
            });
            continue;
        }

        SpecResult? resultData = agent.run(
            api.docs_url,
            apiName = api.name,
            maxIterations = 6,
            targetTitle = api.target_spec
        );

        ResultEntry result;
        string symbol;
        string versionTag;

        if resultData is SpecResult {
            result = {
                name: api.name,
                docs_url: api.docs_url,
                target_spec: api.target_spec,
                spec_url: resultData.spec_url,
                version: resultData.version,
                format: resultData.format,
                title: resultData.title,
                status: "found",
                is_new_version: resultData.is_new_version,
                check_frequency_days: api.check_frequency_days,
                found_at: time:utcToString(time:utcNow())
            };
            symbol = "✓";
            versionTag = resultData.is_new_version
                ? string `  (NEW VERSION: ${resultData.version ?: "?"})`
                : string `  v${resultData.version ?: "?"}`;
        } else {
            result = {
                name: api.name,
                docs_url: api.docs_url,
                target_spec: api.target_spec,
                spec_url: (),
                version: (),
                format: (),
                title: (),
                status: "not_found",
                is_new_version: false,
                check_frequency_days: api.check_frequency_days,
                found_at: ()
            };
            symbol = "✗";
            versionTag = "";
        }

        results.push(result);
        string specDisplay = result.spec_url ?: "Not found";
        io:println(string `\n${symbol} ${api.name}: ${specDisplay}${versionTag}`);
    }

    // ── Save JSON ──
    json output = results.toJson();
    check io:fileWriteString(outputFile, output.toJsonString());

    // ── Summary ──
    io:println(string `\n${repeatString("=", 70)}`);
    io:println(string `Results saved to : ${outputFile}`);
    io:println(repeatString("=", 70));

    int found   = results.filter(r => r.status == "found").length();
    int newVer  = results.filter(r => r.is_new_version).length();
    int skipped = results.filter(r => r.status == "skipped").length();

    io:println(string `\nSummary: ${found}/${results.length()} found  |  ${newVer} new version(s)  |  ${skipped} skipped\n`);

    foreach ResultEntry r in results {
        if r.status == "found" {
            string tag  = r.is_new_version ? " ← NEW VERSION" : "";
            string fmt  = (r.format ?: "?").toUpperAscii();
            string name = r.name;
            // Left-pad name to 30 chars
            string padded = name.length() < 30 ? name + repeatString(" ", 30 - name.length()) : name;
            io:println(string `  ✓ ${padded} ${fmt}  v${r.version ?: "?"}  ${r.spec_url ?: ""}${tag}`);
        } else if r.status == "skipped" {
            io:println(string `  - ${r.name} skipped`);
        } else {
            io:println(string `  ✗ ${r.name} not found`);
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// ENTRY POINT
// ─────────────────────────────────────────────────────────────────────────────

public function main() returns error? {
    check batchFindSpecs();
}
