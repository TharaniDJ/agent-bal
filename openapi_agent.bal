import ballerina/http;
import ballerina/io;
import ballerina/file;
import ballerina/time;
import ballerina/lang.regexp;

// ─────────────────────────────────────────────────────────────────────────────
// TYPES
// ─────────────────────────────────────────────────────────────────────────────

public type MemoryEntry record {
    string? spec_repo = ();
    string[]? useful_pages = ();
    string? last_found_version = ();
    string? search_notes = ();
    string? last_search_outcome = ();
    string? last_found_url = ();
    string? last_searched = ();
};

public type ValidationResult record {
    boolean valid;
    string? version;
    string? title;
    string? format;
    string? 'error;
};

public type AgentOutput record {
    string[] candidates;
    string? search_notes;
    string? spec_repo;
    string[] useful_pages;
};

public type SpecResult record {
    string spec_url;
    string? version;
    string? format;
    string? title;
    boolean is_new_version;
};

public type PageResult record {
    string url;
    string 'type;
    string? content = ();
    string? 'error = ();
    LinkEntry[]? relevant_links = ();
};

public type LinkEntry record {
    string text;
    string href;
};

// ─────────────────────────────────────────────────────────────────────────────
// MEMORY
// ─────────────────────────────────────────────────────────────────────────────

const MEMORY_FILE = "search_memory.json";

function memoryKey(string docsUrl) returns string {
    // Extract netloc + path, strip trailing slash
    string noSchema = docsUrl;
    if noSchema.startsWith("https://") {
        noSchema = noSchema.substring(8);
    } else if noSchema.startsWith("http://") {
        noSchema = noSchema.substring(7);
    }
    // Remove query/fragment
    int? qIdx = noSchema.indexOf("?");
    if qIdx is int {
        noSchema = noSchema.substring(0, qIdx);
    }
    int? hIdx = noSchema.indexOf("#");
    if hIdx is int {
        noSchema = noSchema.substring(0, hIdx);
    }
    // Strip trailing slash
    if noSchema.endsWith("/") {
        noSchema = noSchema.substring(0, noSchema.length() - 1);
    }
    return noSchema;
}

function loadMemory() returns map<MemoryEntry> {
    boolean|file:Error existsOrErr = file:test(MEMORY_FILE, file:EXISTS);
    if existsOrErr is file:Error || !existsOrErr {
        return {};
    }
    string|error content = io:fileReadString(MEMORY_FILE);
    if content is error {
        return {};
    }
    map<MemoryEntry>|error parsed = content.fromJsonStringWithType();
    if parsed is error {
        return {};
    }
    return parsed;
}

function saveMemory(map<MemoryEntry> memory) {
    string|error jsonStr = memory.toJsonString();
    if jsonStr is string {
        error? writeErr = io:fileWriteString(MEMORY_FILE, jsonStr);
        if writeErr is error {
        }
    }
}

public function getMemoryEntry(string docsUrl) returns MemoryEntry? {
    map<MemoryEntry> memory = loadMemory();
    string key = memoryKey(docsUrl);
    return memory[key];
}

function updateMemoryEntry(string docsUrl, MemoryEntry updates) {
    map<MemoryEntry> memory = loadMemory();
    string key = memoryKey(docsUrl);
    MemoryEntry existing = memory.hasKey(key) ? memory.get(key) : {};

    if updates.spec_repo is string    { existing.spec_repo = updates.spec_repo; }
    if updates.useful_pages is string[] { existing.useful_pages = updates.useful_pages; }
    if updates.last_found_version is string { existing.last_found_version = updates.last_found_version; }
    if updates.search_notes is string { existing.search_notes = updates.search_notes; }
    if updates.last_search_outcome is string { existing.last_search_outcome = updates.last_search_outcome; }
    if updates.last_found_url is string { existing.last_found_url = updates.last_found_url; }

    // Timestamp
    existing.last_searched = time:utcToString(time:utcNow());
    memory[key] = existing;
    saveMemory(memory);
}

function buildMemoryHint(MemoryEntry entry) returns string {
    string[] parts = [];

    if entry.spec_repo is string {
        parts.push(
            string `Previously the spec was found in this repository: ${entry.spec_repo ?: ""}. ` +
            "Start there and check for the latest release or version."
        );
    }
    string[]? pages = entry.useful_pages;
    if pages is string[] && pages.length() > 0 {
        string pageLines = "\n".join(...from string p in pages.slice(0, pages.length() < 5 ? pages.length() : 5)
                                        select string `  - ${p}`);
        parts.push(string `These pages were useful last time:\n${pageLines}`);
    }
    if entry.last_found_version is string {
        parts.push(
            string `The last known spec version was ${entry.last_found_version ?: ""}. ` +
            "Look for anything newer — but always return the latest regardless."
        );
    }
    if entry.search_notes is string {
        parts.push(string `Notes from last search: ${entry.search_notes ?: ""}`);
    }
    if parts.length() == 0 {
        return "";
    }
    return "\n\n## Memory from previous search\n" + "\n".join(...parts) +
           "\n\nUse this as a starting hint only. Always verify you have the LATEST version.";
}

function getHeaderOrEmpty(http:Response resp, string name) returns string {
    string|http:HeaderNotFoundError h = resp.getHeader(name);
    if h is string {
        return h;
    }
    return "";
}

isolated function splitByDelimiter(string value, string delimiter) returns string[] {
    if delimiter == "" {
        return [value];
    }
    string[] parts = [];
    string remaining = value;
    while true {
        int? idx = remaining.indexOf(delimiter);
        if idx is int {
            parts.push(remaining.substring(0, idx));
            remaining = remaining.substring(idx + delimiter.length());
        } else {
            parts.push(remaining);
            break;
        }
    }
    return parts;
}

isolated function firstVersionNumber(string version) returns int {
    string[] parts = splitByDelimiter(version, ".");
    if parts.length() == 0 {
        return 0;
    }
    int|error v = int:fromString(parts[0]);
    if v is int {
        return v;
    }
    return 0;
}

function yamlScalar(string text, string key) returns string? {
    string prefix = key + ":";
    string[] lines = splitByDelimiter(text, "\n");
    foreach string rawLine in lines {
        string line = rawLine.trim();
        if line.startsWith(prefix) {
            string value = line.substring(prefix.length()).trim();
            if value.startsWith("\"") && value.endsWith("\"") && value.length() > 1 {
                return value.substring(1, value.length() - 1);
            }
            if value.startsWith("'") && value.endsWith("'") && value.length() > 1 {
                return value.substring(1, value.length() - 1);
            }
            return value;
        }
    }
    return ();
}

function jsonValueAsString(map<json> dataMap, string key) returns string {
    if !dataMap.hasKey(key) {
        return "";
    }
    json value = dataMap[key];
    if value is string {
        return value;
    }
    return value.toString();
}

// ─────────────────────────────────────────────────────────────────────────────
// HTTP HELPERS
// ─────────────────────────────────────────────────────────────────────────────

function fetchRaw(string url) returns http:Response|error {
    http:Client cl = check new (url, {
        followRedirects: { enabled: true, maxCount: 5 },
        timeout: 20
    });
    http:Response resp = check cl->get("", {
        "User-Agent": "OpenAPI-Spec-Finder/4.0"
    });
    return resp;
}

function headCheck(string url) returns boolean {
    do {
        http:Client cl = check new (url, {
            followRedirects: { enabled: true, maxCount: 5 },
            timeout: 10
        });
        http:Response resp = check cl->head("", {
            "User-Agent": "OpenAPI-Spec-Finder/4.0"
        });
        return resp.statusCode == 200;
    } on fail {
        return false;
    }
}

function githubBlobToRaw(string url) returns string {
    string result = url;
    string ghPrefix = "https://github.com/";
    if result.startsWith(ghPrefix) {
        result = "https://raw.githubusercontent.com/" + result.substring(ghPrefix.length());
    }
    int? blobIdx = result.indexOf("/blob/");
    if blobIdx is int {
        result = result.substring(0, blobIdx) + "/" + result.substring(blobIdx + 6);
    }
    return result;
}

// ─────────────────────────────────────────────────────────────────────────────
// VALIDATORS
// ─────────────────────────────────────────────────────────────────────────────

function parseSpec(string text) returns map<json>|error {
    // Try JSON first
    json|error j = text.fromJsonString();
    if j is map<json> {
        return j;
    }
    // Try YAML — Ballerina doesn't have built-in YAML parsing,
    // so we do a minimal key-scan to support simple cases.
    // For production use, add a YAML library via Ballerina Central.
    return error("Cannot parse as JSON or YAML");
}

function validateOpenApiSpec(string url) returns ValidationResult {
    ValidationResult result = {
        valid: false, version: (), title: (), format: (), 'error: ()
    };

    http:Response|error respOrErr = fetchRaw(url);
    if respOrErr is error {
        result.'error = "Could not fetch URL";
        return result;
    }
    http:Response resp = respOrErr;
    string|error textOrErr = resp.getTextPayload();
    if textOrErr is error {
        result.'error = "Could not read body";
        return result;
    }
    string text = textOrErr.trim();
    string ct = getHeaderOrEmpty(resp, "content-type");

    if url.endsWith(".yaml") || url.endsWith(".yml") || ct.includes("yaml") {
        result.format = "yaml";
    } else if url.endsWith(".json") || ct.includes("json") {
        result.format = "json";
    } else {
        result.format = (text.startsWith("openapi:") || text.startsWith("swagger:")) ? "yaml" : "json";
    }

    map<json>|error data = parseSpec(text);
    if data is error {
        // For YAML specs, do a simple key search
        if text.includes("openapi:") {
            result.valid = true;
            result.version = yamlScalar(text, "openapi") ?: "?";
            result.title = yamlScalar(text, "title");
            return result;
        }
        if text.includes("swagger:") {
            result.valid = true;
            result.version = "2.0";
            return result;
        }
        result.'error = "Could not parse";
        return result;
    }

    if data.hasKey("openapi") {
        result.valid = true;
        result.version = (data["openapi"] ?: "?").toString();
    } else if data.hasKey("swagger") {
        result.valid = true;
        result.version = (data["swagger"] ?: "?").toString();
    } else {
        result.'error = "No 'openapi' or 'swagger' key found";
        return result;
    }

    json infoJson = data["info"] ?: {};
    if infoJson is map<json> {
        result.title = (infoJson["title"] ?: ()).toString();
    }
    return result;
}

function bestValidatedUrl(string[] candidates) returns [string, ValidationResult]? {
    [string, ValidationResult][] valid = [];

    foreach string rawUrl in candidates {
        string url = rawUrl.trim();
        if url == "" || !url.startsWith("http") {
            continue;
        }
        if url.includes("github.com") && url.includes("/blob/") {
            url = githubBlobToRaw(url);
        }
        io:println(string `  [head-check] ${url}`);
        if !headCheck(url) {
            io:println("    ✗ not reachable (skipping full download)");
            continue;
        }
        io:println(string `  [validate]   ${url}`);
        ValidationResult vr = validateOpenApiSpec(url);
        if vr.valid {
            valid.push([url, vr]);
            io:println(string `    ✓ valid  version=${vr.version ?: "?"}  format=${vr.format ?: "?"}  title=${vr.title ?: "?"}`);
        } else {
            io:println(string `    ✗ invalid: ${vr.'error ?: "unknown"}`);
        }
    }

    if valid.length() == 0 {
        return ();
    }

    // Sort: prefer higher OpenAPI version, then YAML over JSON
    var sorted = valid.sort("descending", isolated function([string, ValidationResult] item) returns int {
        [string, ValidationResult] [_, vr] = item;
        int fmtScore = vr.format == "yaml" ? 1 : 0;
        int verScore = 0;
        string ver = vr.version ?: "0";
        verScore = firstVersionNumber(ver);
        return verScore * 10 + fmtScore;
    });
    return sorted[0];
}

// ─────────────────────────────────────────────────────────────────────────────
// FETCH PAGE TOOL (called by the agent via tool_use)
// ─────────────────────────────────────────────────────────────────────────────

public function fetchPage(string url) returns PageResult {
    http:Response|error respOrErr = fetchRaw(url);
    if respOrErr is error {
        return { url, 'type: "error", 'error: "Request failed" };
    }
    http:Response resp = respOrErr;
    string ct = getHeaderOrEmpty(resp, "content-type");
    string|error textOrErr = resp.getTextPayload();
    if textOrErr is error {
        return { url, 'type: "error", 'error: "Could not read body" };
    }
    string text = textOrErr;

    if ct.includes("json") || url.endsWith(".json") {
        return { url, 'type: "json", content: text.substring(0, text.length() < 40000 ? text.length() : 40000) };
    }
    if ct.includes("yaml") || url.endsWith(".yaml") || url.endsWith(".yml") {
        return { url, 'type: "yaml", content: text.substring(0, text.length() < 40000 ? text.length() : 40000) };
    }

    // HTML: extract text + relevant links (basic, no HTML parser in stdlib)
    // Strip script/style blocks crudely
    string stripped = regexp:replaceAll(re `<script[^>]*>[\s\S]*?</script>`, text, "");
    stripped = regexp:replaceAll(re `<style[^>]*>[\s\S]*?</style>`, stripped, "");
    stripped = regexp:replaceAll(re `<[^>]+>`, stripped, " ");
    stripped = regexp:replaceAll(re `\s{2,}`, stripped, "\n");
    string pageText = stripped.substring(0, stripped.length() < 15000 ? stripped.length() : 15000);

    return { url, 'type: "html", content: pageText, relevant_links: [] };
}

// ─────────────────────────────────────────────────────────────────────────────
// SYSTEM PROMPT
// ─────────────────────────────────────────────────────────────────────────────

const BASE_SYSTEM_PROMPT = "You are an expert OpenAPI spec finder agent. Your ONLY job is to find the direct URL(s) to an API's LATEST official OpenAPI specification file (JSON or YAML).\n\n## Step-by-step strategy\n\n### Step 1 — Read the official docs page FIRST\nAlways start by fetching the starting documentation URL given to you.\nCarefully read ALL links on that page. API documentation pages often directly mention or link to their OpenAPI spec — look for:\n- Text like \"OpenAPI Specification\", \"Swagger\", \"Download spec\", \"API spec\", \"generated from our OpenAPI spec\"\n- Any link containing: openapi, swagger, .yaml, .yml, .json, spec, defs, raw.githubusercontent\n\n### Step 2 — Construct raw GitHub URLs immediately (do NOT keep fetching tree pages)\nIf you find a GitHub repository link or a file path reference:\n- DO NOT fetch github.com/owner/repo/tree/branch/path pages — these are HTML pages, not spec files\n- Instead, IMMEDIATELY construct the raw URL:\n  github.com/owner/repo/blob/branch/path/file.yaml → raw.githubusercontent.com/owner/repo/branch/path/file.yaml\n- Report the constructed raw URL as a candidate right away\n\n### Step 3 — Pick the highest version\nWhen multiple versioned files exist (e.g. swagger-v2.json and swagger-v2.1.json):\n- Always prefer the highest version number (v2.1 > v2, v3 > v2)\n- Look for the version number in the FILENAME itself\n- Also check GitHub Releases/Tags for the latest release tag\n\n### Step 4 — Prefer YAML over JSON at the same version\n\n## Efficiency rules\n- Fetch the starting docs page first — read it carefully before going anywhere else\n- Fetch at MOST 4 pages total\n- Never fetch github.com tree/blob pages to \"see\" files — construct raw URLs directly instead\n- Never fetch the same URL twice\n\n## Output format — output EXACTLY this block when done:\n\nSPEC_CANDIDATES:\n<url1>\n<url2>\nSEARCH_NOTES: <one sentence about where/how you found it>\nSPEC_REPO: <GitHub or source repo URL if applicable, else omit>\nUSEFUL_PAGES: <comma-separated pages that helped>\n\nIf no public spec exists after thorough search:\nNO_SPEC_FOUND\n";

// ─────────────────────────────────────────────────────────────────────────────
// ANTHROPIC CLIENT & AGENT
// ─────────────────────────────────────────────────────────────────────────────

type ContentBlock record {
    string 'type;
    string? text;
    string? id;
    string? name;
    map<json>? input;
};

type AnthropicResponse record {
    string stop_reason;
    ContentBlock[] content;
};

type AnthropicMessage record {
    string role;
    json content; // string or ContentBlock[]
};

type ToolResultContent record {
    string 'type;
    string tool_use_id;
    string content;
};

public class OpenAPIAgent {
    private string apiKey;
    private http:Client anthropicClient;

    public function init(string apiKey) returns error? {
        self.apiKey = apiKey;
        self.anthropicClient = check new ("https://api.anthropic.com", {
            timeout: 60
        });
    }

    function parseAgentOutput(string text) returns AgentOutput {
        AgentOutput result = { candidates: [], search_notes: (), spec_repo: (), useful_pages: [] };
        if !text.includes("SPEC_CANDIDATES:") {
            return result;
        }
        int? markerIdx = text.indexOf("SPEC_CANDIDATES:");
        if markerIdx is () {
            return result;
        }
        string after = text.substring(markerIdx + "SPEC_CANDIDATES:".length());
        string[] lines = splitByDelimiter(after, "\n");
        foreach string rawLine in lines {
            string line = rawLine.trim();
            if line.startsWith("http") {
                result.candidates.push(line);
            } else if line.startsWith("SEARCH_NOTES:") {
                result.search_notes = line.substring("SEARCH_NOTES:".length()).trim();
            } else if line.startsWith("SPEC_REPO:") {
                result.spec_repo = line.substring("SPEC_REPO:".length()).trim();
            } else if line.startsWith("USEFUL_PAGES:") {
                string raw = line.substring("USEFUL_PAGES:".length()).trim();
                result.useful_pages = from string p in splitByDelimiter(raw, ",")
                                      where p.trim() != ""
                                      select p.trim();
            }
        }
        return result;
    }

    public function run(
        string startingUrl,
        string apiName = "",
        int maxIterations = 6,
        string? targetTitle = ()
    ) returns SpecResult? {

        MemoryEntry? memEntry = getMemoryEntry(startingUrl);
        string memoryHint = memEntry is MemoryEntry ? buildMemoryHint(memEntry) : "";
        string? lastKnownVersion = memEntry?.last_found_version;

        if memoryHint != "" {
            io:println("  [memory] Previous search data found — guiding agent navigation");
            if lastKnownVersion is string {
                io:println(string `  [memory] Last known version: ${lastKnownVersion}`);
            }
        }

        string systemPrompt = BASE_SYSTEM_PROMPT + memoryHint;

        string userMsg = string `Find the LATEST OpenAPI spec URL starting from: ${startingUrl}\n`;
        if apiName != "" {
            userMsg += string `API name: ${apiName}\n`;
        }
        if targetTitle is string {
            userMsg += string `Target spec: look specifically for the spec titled '${targetTitle}' among the available specs on this page.\n`;
        }
        if lastKnownVersion is string {
            userMsg += string `The last known version was ${lastKnownVersion}. Check if a newer version exists — but always return the latest regardless.\n`;
        }
        userMsg += "\nIMPORTANT: Use the fetch_page tool to fetch the starting docs page first. Read ALL content carefully before going elsewhere. Fetch at most 4 pages total. Output SPEC_CANDIDATES: as soon as you have plausible URLs.";

        // Tool definition — enables Claude to actually browse pages
        json[] agentTools = [
            {
                "name": "fetch_page",
                "description": "Fetch a web page or file URL and return its content. Use this to explore documentation pages, GitHub repositories, and raw spec files.",
                "input_schema": {
                    "type": "object",
                    "properties": {
                        "url": {
                            "type": "string",
                            "description": "The URL to fetch"
                        }
                    },
                    "required": ["url"]
                }
            }
        ];

        // Conversation history — grows as tools are called
        json[] messages = [
            {
                "role": "user",
                "content": userMsg
            }
        ];

        string fullText = "";
        AgentOutput? parsedOutput = ();
        int iteration = 0;

        // ── Agentic loop ──
        while iteration < maxIterations {
            iteration += 1;
            io:println(string `  [agent] Iteration ${iteration}/${maxIterations}`);

            json requestBody = {
                "model": "claude-sonnet-4-20250514",
                "max_tokens": 4096,
                "system": systemPrompt,
                "tools": agentTools,
                "messages": messages
            };

            http:Response|error respOrErr = self.anthropicClient->post(
                "/v1/messages",
                requestBody,
                {
                    "x-api-key": self.apiKey,
                    "anthropic-version": "2023-06-01",
                    "content-type": "application/json"
                }
            );

            if respOrErr is error {
                io:println(string `  [error] API call failed: ${respOrErr.message()}`);
                return ();
            }

            json|error bodyOrErr = respOrErr.getJsonPayload();
            if bodyOrErr is error {
                io:println("  [error] Could not parse API response");
                return ();
            }

            if !(bodyOrErr is map<json>) {
                io:println("  [error] Unexpected API response format");
                return ();
            }

            map<json> body = bodyOrErr;
            string stopReason = jsonValueAsString(body, "stop_reason");
            json contentJson = body.hasKey("content") ? body["content"] : [];

            if !(contentJson is json[]) {
                io:println("  [error] No content array in response");
                return ();
            }

            json[] contentBlocks = <json[]>contentJson;

            // Accumulate any text output from this turn
            foreach json block in contentBlocks {
                if block is map<json> {
                    string blockType = jsonValueAsString(block, "type");
                    if blockType == "text" {
                        fullText += jsonValueAsString(block, "text") + "\n";
                    }
                }
            }

            if fullText.includes("NO_SPEC_FOUND") {
                io:println("  Agent reports no spec found.");
                updateMemoryEntry(startingUrl, {last_search_outcome: "not_found"});
                return ();
            }

            // If agent output the final answer, or naturally finished, stop looping
            if fullText.includes("SPEC_CANDIDATES:") || stopReason == "end_turn" {
                if fullText.includes("SPEC_CANDIDATES:") {
                    parsedOutput = self.parseAgentOutput(fullText);
                }
                break;
            }

            // If stop reason is not tool_use, nothing more to do
            if stopReason != "tool_use" {
                io:println(string `  [agent] Stop reason: ${stopReason} — ending loop`);
                break;
            }

            // ── Execute tool calls ──
            // Append assistant's response (with tool_use blocks) to conversation
            json assistantMessage = {
                "role": "assistant",
                "content": contentBlocks
            };
            messages.push(assistantMessage);

            // Build tool_result blocks
            json[] toolResults = [];
            foreach json block in contentBlocks {
                if block is map<json> {
                    string blockType = jsonValueAsString(block, "type");
                    if blockType == "tool_use" {
                        string toolId = jsonValueAsString(block, "id");
                        string toolName = jsonValueAsString(block, "name");

                        string fetchUrl = "";
                        json inputVal = block.hasKey("input") ? block["input"] : {};
                        if inputVal is map<json> && inputVal.hasKey("url") {
                            json urlVal = inputVal["url"];
                            if urlVal is string {
                                fetchUrl = urlVal;
                            }
                        }

                        string resultContent;
                        if toolName == "fetch_page" && fetchUrl != "" {
                            io:println(string `  [tool] fetch_page(${fetchUrl})`);
                            PageResult pr = fetchPage(fetchUrl);
                            if pr.'error is string {
                                resultContent = string `Error fetching URL: ${pr.'error ?: "unknown"}`;
                            } else {
                                resultContent = string `URL: ${pr.url}\nType: ${pr.'type}\nContent:\n${pr.content ?: "(empty)"}`;
                            }
                        } else {
                            resultContent = string `Unknown tool '${toolName}' or missing URL parameter`;
                        }

                        toolResults.push({
                            "type": "tool_result",
                            "tool_use_id": toolId,
                            "content": resultContent
                        });
                    }
                }
            }

            if toolResults.length() == 0 {
                io:println("  [agent] No tool calls found despite tool_use stop reason — ending loop");
                break;
            }

            // Append tool results as next user turn
            json toolResultMessage = {
                "role": "user",
                "content": toolResults
            };
            messages.push(toolResultMessage);
        }

        // ── Validation ──
        AgentOutput? po = parsedOutput;
        if po is () || po.candidates.length() == 0 {
            io:println("  No candidates collected from agent.");
            return ();
        }

        io:println(string `\n[validation] ${po.candidates.length()} candidate(s) — HEAD pre-checking then validating…`);
        [string, ValidationResult]? best = bestValidatedUrl(po.candidates);
        if best is () {
            io:println("  No candidates passed validation.");
            return ();
        }
        [string, ValidationResult] [bestUrl, vr] = best;

        // ── Version comparison ──
        boolean isNewVersion = false;
        string? lkv = lastKnownVersion;
        if lkv is string && vr.version is string {
            int[] oldParts = [];
            int[] newParts = [];
            boolean parsed = true;

            foreach string p in splitByDelimiter(lkv, ".") {
                int|error num = int:fromString(p);
                if num is int {
                    oldParts.push(num);
                } else {
                    parsed = false;
                    break;
                }
            }
            if parsed {
                foreach string p in splitByDelimiter(vr.version ?: "0", ".") {
                    int|error num = int:fromString(p);
                    if num is int {
                        newParts.push(num);
                    } else {
                        parsed = false;
                        break;
                    }
                }
            }

            if parsed {
                int minLen = oldParts.length() < newParts.length() ? oldParts.length() : newParts.length();
                int i2 = 0;
                while i2 < minLen {
                    if newParts[i2] > oldParts[i2] { isNewVersion = true; break; }
                    if newParts[i2] < oldParts[i2] { break; }
                    i2 += 1;
                }
            } else {
                isNewVersion = vr.version != lkv;
            }
        }

        // ── Update memory ──
        MemoryEntry memUpdate = {
            last_found_version: vr.version,
            last_found_url: bestUrl,
            last_search_outcome: "found"
        };
        if po.spec_repo is string { memUpdate.spec_repo = po.spec_repo; }
        if po.useful_pages.length() > 0 { memUpdate.useful_pages = po.useful_pages; }
        if po.search_notes is string { memUpdate.search_notes = po.search_notes; }
        updateMemoryEntry(startingUrl, memUpdate);
        io:println(string `  [memory] Updated for ${memoryKey(startingUrl)}`);

        return {
            spec_url: bestUrl,
            version: vr.version,
            format: vr.format,
            title: vr.title,
            is_new_version: isNewVersion
        };
    }
}
