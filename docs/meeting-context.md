# MCP context for meeting notes

Meeting Transcriber can look up unfamiliar names and terminology before writing meeting notes. Context is off by default. Keep **Save raw transcript separately** enabled if you want to regenerate notes later. Context enrichment uses the finalized transcript and adds external evidence to the notes request. The app's recording, transcription, speaker labeling, and existing output options continue to apply.

## Configure your notes provider

In **Settings → Output**, choose **OpenAI-compatible API**. Select or add a connection, enter the model ID, test the connection, and select a model that can follow instructions and return a plain-text JSON plan. For an existing local Ollama endpoint, the base URL is typically `http://127.0.0.1:11434/v1`. Use the API key field only if your endpoint requires one. An existing LM Studio or llama.cpp server can use its own OpenAI-compatible base URL.

In **Context & MCP**, turn on **Use MCP context when generating meeting notes**. An eligible job sends one extra model request with the complete finalized transcript and the approved tool catalog. Loopback endpoints count as local. A loopback server or proxy can still relay data to another service. For non-loopback notes endpoints, each MCP source needs separate permission for the selected HTTPS endpoint. Editing the notes URL requires fresh permission for that destination.

Claude CLI continues to generate ordinary notes. Context enrichment is unavailable with that adapter, including its optional tool modes. The App Store build supports HTTP sources. Local stdio sources and menu-driven regeneration from picked files require a non-App-Store build.

## Configure a local stdio source

1. In **Settings → Output → Context & MCP**, choose **Add MCP Source…** and set **Transport** to **Local stdio**.
2. Enter an installed server's absolute executable path, such as `/absolute/path/to/knowledge-mcp`, and a JSON argument array, such as `["--profile","personal"]`. The app launches this executable with an argument array.
3. If the server needs environment values, select **Replace saved credentials** and enter a JSON object such as `{"KNOWLEDGE_API_TOKEN":"<your-token>"}`. These values are stored in Keychain. The subprocess gets a minimal default environment plus the values you specify. Put secret values in this field instead of the argument array.
4. Select **Save and Test Connection**. Review the discovered names, descriptions and hints. Approve the specific read-only retrieval tools you want the app to use.
5. Select **Enable source for notes**, choose any forwarding or retention permissions you need, and save.

## Configure a Streamable HTTP source

1. Add an MCP source and set **Transport** to **Streamable HTTP**. Enter the endpoint, for example `https://knowledge.example.com/mcp`. Plain HTTP needs **Allow plain HTTP on loopback** and a loopback address such as `http://127.0.0.1:8765/mcp`.
2. Choose how the server authenticates you.
   - For browser sign-in, choose **OAuth sign-in**, select **Sign In in Browser…**, and grant access in your browser. Start with just the HTTPS server URL. The app discovers the authorization server and uses its supported public client registration.
   - For static headers, choose **None or static headers**. Select **Replace saved credentials** and enter a JSON object, such as `{"Authorization":"Bearer <your-token>"}` or `{"X-API-Key":"<your-token>"}`. Use `{}` in the credentials field to clear saved headers.
3. Test the connection and approve individual read-only tools. A successful browser sign-in runs the test automatically. The connection test initializes the server and lists tools without sending meeting data.
4. Enable the source and explicitly allow **meeting lookup arguments to this HTTP endpoint**. If your notes provider is remote, optionally approve forwarding this source's metadata and evidence to the selected notes endpoint. Save.

New sources are disabled with no tool approvals. The enabled sources and their explicit permissions form the global source policy for automatic notes. Enable work and personal sources together only for meetings where you want both consulted. Editing an MCP source's transport, address, launch arguments or credentials clears tool approvals. A change to discovered tool metadata also requires review and renewed approval. Disable a source or revoke its approvals to stop further lookups and withhold late results. The server's read-only hint is advisory. Approve tools on servers you trust, including local servers that may contact external services.

### OAuth compatibility

The app supports OAuth authorization code sign-in with PKCE (S256). It can use the app's public client metadata document after the project site publishes it, or register a public client dynamically when the server offers that option. If your provider gives you a public client ID or public HTTPS client metadata URL, enter it in **OAuth client ID or metadata URL (optional)**. Configure that client to allow `http://127.0.0.1:47863/oauth/callback` and unauthenticated token exchange for a public client. The app listens on that loopback address while you sign in. Both app variants support this callback.

OAuth tokens and static headers are saved in Keychain. A source's bearer token is sent only to its configured MCP endpoint. Refresh uses the detected authorization server. If the session expires and refresh is unavailable, sign in again in Settings. **Forget Sign-In** clears the authorization from this Mac and clears tool approvals. You can revoke server-side consent from the provider's account settings.

## Generate and regenerate

Automatic notes, failed-note retries, and **Generate Meeting Notes from Transcript…** use configured context when eligible. After initialization and paginated discovery, the app asks the notes model for proposed lookups as JSON. The app checks tool approval, source and provider permissions, transcript references, argument schema and egress limits before it calls a tool. It completes one retrieval round. The final model request includes the original transcript and separate quoted evidence, with instructions to preserve uncertain names and distinguish meeting statements from external facts. The model receives no tools. If a plan, source, or result is unavailable, ordinary notes continue using the configured provider. Usable results from other approved sources can still contribute.

To replace local notes, select **Regenerate Meeting Notes → Use Configured Context…** or **Without Context…** and choose the saved `.txt`. **Use Configured Context** follows the global toggle and source permissions. The app reads the transcript directly and writes local Markdown with the same stem. A generation failure or a detectable edit to the existing notes during the request preserves the previous file. The replacement action writes local notes only. Ordinary notes exported to Notion can include names resolved with context. The ordinary **Generate Meeting Notes from Transcript…** action still skips existing notes.

The job row and completion notification show whether context was used, partial, skipped, unnecessary, or failed. A cancelled job produces no new notes. For an enrichment attempt, the app writes a private `<stem>.context.json` beside the notes. The record includes sanitized status, tool and segment identifiers, retrieval times and a digest of the notes it describes. Evidence is included only for sources with **Keep supplied evidence in the local context record** enabled. Metadata-only records omit evidence text, including source references embedded in that text. They still identify the source, tool, request and original segment IDs. Match `notesSHA256` to the Markdown before treating a record as provenance for the current notes. Notes and records are written atomically as individual files. Keep or delete the generated record with its meeting outputs. The record remains in the output folder for Notion-only jobs after their local Markdown backup is removed.

## Limits and compatibility

- The app supports MCP stdio and Streamable HTTP with static headers or OAuth. Streamable HTTP accepts JSON and POST response SSE, and uses negotiated session headers. Standalone SSE subscriptions, legacy HTTP+SSE, server-initiated operations, and fetching resources or attachments are outside this implementation.
- Tool inputs use a strict JSON Schema subset covering typed objects, arrays and scalars, declared properties, required fields, additional-property rules, enum and const, and supported size and numeric ranges. Unsupported constraints, including schema references, composition and patterns, require a compatible tool schema. Schema defaults, examples, and annotations are removed from data sent to the model.
- The app allows up to eight sources, four discovery pages and 48 discovered tools per source, and twelve lookups in one sequential round. The enrichment stage has a 90-second budget, with up to 15 seconds per MCP operation and 30 seconds for planning. A lookup's serialized arguments are capped at 4 KiB with a 384-byte textual allowance per call and a 1 KiB textual allowance per meeting. Normalized results are capped at 32 KiB per call, wire responses at 128 KiB, and the final evidence bundle at 16 KiB. The settings connection test has a 30-second budget. A successful enriched attempt ordinarily makes two model requests. Provider compatibility retries can add requests.
- Planning uses all nonblank transcript lines with their original line-derived IDs. If the transcript and a usable catalog cannot fit within the 20 KiB planner input budget, the app skips enrichment and reports it. The 48 KiB enriched notes input cap includes the template, transcript and evidence. These are byte budgets. A model may have a smaller effective context window, and ordinary notes keep the provider's own limits.
- The app shares the 16 KiB evidence budget across the lookups in a meeting. Small responses fit in full. For larger text responses within the wire cap, the app keeps a contiguous excerpt around the lookup terms. The context record uses `evidenceExcerpted` when this happens. Successful decoded results can record `responseContentBytes` after filtering and `evidenceContentBytes` after shortening. A response that exceeds the wire cap is recorded as `responseTooLarge`. Keeping supplied evidence saves the text used for the notes, which may be an excerpt.
- The app bounds and checks what crosses each destination, including known secret values and common credential patterns. Automatic detection of confidential content is imperfect. Model decisions about aliases and ambiguity can also be wrong. A context record documents the input to the model and does not verify a correction.

## Verification

### Measure a Streamable HTTP response

From the repository root, use the Python wrapper around `curl` to list the server's tools and measure a single read-only call. Replace the URL and use the argument names from the selected tool's advertised schema.

```sh
python3 scripts/probe-mcp-response.py 'https://your-server.example/mcp' --bearer
python3 scripts/probe-mcp-response.py 'https://your-server.example/mcp' \
  search '{"query":"a short test query","limit":1}' --bearer
```

`--bearer` prompts for a provider-issued token. Omit it for public or local servers that require no authentication. The probe reports body bytes through the matching JSON-RPC response and estimates how much normalized content the result contains. Actual evidence size also depends on safety filtering, metadata, and the other lookups in the meeting. A body above 131,072 bytes exceeds the app's wire cap. Try a smaller result count or excerpt size if the tool supports those arguments.

### Run the Swift tests

Run the targeted tests on macOS with Xcode 26 or later and Python 3 available for the synthetic MCP fixtures.

```sh
cd app/MeetingTranscriber
swift test --filter 'MCPOAuthTests|ContextMCPTests|ContextPolicyTests|PipelineMeetingContextTests'
swift build --build-tests
../../scripts/ci/test-shards.sh run --shards 3 --skip ModelPreloadTests
```

For a live check, use an existing local notes model and a trusted test source with synthetic names. Try a transcript with a misheard project term, then a transcript with two plausible speaker identities. Check the notes, source permissions, context record and unchanged transcript digest. Repeat after disabling the source or stopping its server. Regenerate the same transcript with context and without it, then cause a model failure and check that the last successful notes still open.


### Controlled local model results

Synthetic smoke tests on Linux used llama.cpp b12721 with Qwen2.5 1.5B Instruct and 3B Instruct (Q4_K_M). Both models returned usable lookup plans and received evidence from the controlled HTTP source. The 1.5B model put the canonical project name in the participants list. The 3B model kept the spoken project alias. Both preserved the ambiguity of the person's full name, and the samples also contained unsupported participant labels or task attributions. Retrieval and evidence forwarding succeeded in these checks. The semantic acceptance cases still need a suitable model and a macOS app run.
