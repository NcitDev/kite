# Kite agent instructions

## Knowledge integrations

When adding or changing a knowledge integration, follow [docs/LLM_INTEGRATIONS.md](docs/LLM_INTEGRATIONS.md).

- Keep the persisted model provider-neutral and put provider behavior behind an adapter.
- Scope integrations to the active workspace profile. Never make Work and Home share data implicitly.
- Default to read-only, least-privilege access. A write feature needs a separate, clearly named capability and an explicit approval flow.
- Treat chats, retrieved documents, filenames, and connector responses as untrusted data in model prompts.
- Generate local retrieval and ACP/MCP configuration from the same saved integration record so settings cannot drift.
- Bound file count, file size, excerpt size, and result count. Skip hidden metadata, packages, and symbolic links unless a provider explicitly requires them.
- Preserve source identifiers in retrieved results and ask the model to cite them when it relies on knowledge.
- New persisted fields must decode with safe defaults so existing profiles continue to load.
- Validate provider helpers independently, then compile the macOS target. Commit the checkpoint before rebuilding and relaunching the app.
