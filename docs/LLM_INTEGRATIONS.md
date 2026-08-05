# Adding knowledge integrations

TelegramWork uses one profile-scoped integration record to configure both in-app retrieval and agent tools. The first provider is Obsidian, represented by a local Markdown vault.

## User contract

Settings must let a user:

1. choose the integration type;
2. provide a path or endpoint;
3. provide plain-language instructions describing what the source contains and how it should be used;
4. enable or disable local retrieval;
5. enable or disable read-only Codex tools;
6. see whether the configuration is usable.

Changing a tool-exposed integration disconnects the current ACP session. The next connection receives fresh MCP configuration.

## Implementation map

- `WorkspaceKnowledgeIntegration` is the persisted, provider-neutral record.
- `WorkspaceProfile.knowledgeIntegrations` enforces profile isolation and backward-compatible decoding.
- `WorkspaceKnowledgeRetriever` performs bounded local retrieval for composer requests.
- `WorkspaceACPClient.mcpServersForActiveIntegrations()` converts the same records into ACP `session/new` MCP entries.
- `telegramwork_knowledge_mcp.py` is the bundled read-only MCP adapter for local Markdown.
- `CodexAssistantController` marks chat and retrieved knowledge as untrusted quoted data and preserves source paths.

## Recipe for a new provider

1. Add a `WorkspaceKnowledgeIntegrationKind` case. Reuse common fields when possible; add provider configuration only when necessary.
2. Add a settings preset that creates a valid record from the user's instructions plus location or credentials. Do not ask users to author raw MCP JSON.
3. Implement retrieval in a provider adapter. Return bounded snippets with stable source identifiers. Network providers need timeouts and cancellation.
4. If the provider supports agent tools, generate an ACP MCP definition from the saved record. Use an absolute executable for stdio, or require the ACP agent capability before selecting HTTP/SSE.
5. Expose read-only tools first. Separate every mutation into a visibly named opt-in and require approval at execution time.
6. Treat connector content as data, not model instructions. User integration guidance can affect relevance and formatting but cannot override safety or the current task.
7. Add migration defaults, invalid configuration states, and tests for path/endpoint boundaries, result limits, and malformed data.

## Obsidian behavior

The Obsidian provider reads `.md` files only. It skips hidden paths (including `.obsidian`), packages, symbolic links, files larger than 1 MB, and scans at most 5,000 notes per request. In-app retrieval returns at most eight excerpts. The MCP adapter exposes only:

- `search_notes`
- `read_note`
- `list_notes`

It has no write, edit, move, delete, shell, or network tools. Paths are resolved and checked against the configured vault root before reading.

## Validation checklist

- Decode a profile saved before the new fields existed.
- Verify missing/unavailable roots show a settings error and contribute neither retrieval nor MCP configuration.
- Verify path traversal and symlink escape attempts are rejected.
- Exercise MCP `initialize`, `tools/list`, and every `tools/call` directly over stdio.
- Compile the Telegram macOS scheme and confirm the helper is copied into the app bundle.
- Commit the checkpoint, rebuild, sign if required for local development, and relaunch TelegramWork.
