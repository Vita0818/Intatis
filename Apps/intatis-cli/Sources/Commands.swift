import Foundation
import IntatisProviders

func printConfig(_ config: CLIConfig) {
    out("""
    endpoint : (configured, hidden) · \(config.selectedRouteLabel)
    model    : \(config.model)
    wire     : \(config.wire.rawValue)
    reasoning: \(config.reasoningEffort?.rawValue ?? "off")
    mode     : \(config.mode.rawValue)
    api key  : \(config.hasConfiguredCredential ? "(configured, hidden)" : "(unset)")
    routes   : \(config.providerRoutes.count)
    config   : \(config.configurationFileURL == nil ? ConfigFile.url.path : "(advanced Intatis config, path hidden)")

    """)
}

func printHelp() {
    out("""
    Intatis CLI — a local AI agent for ANY OpenAI-compatible endpoint.

    USAGE
      intatis                 Start your default mode (set via `intatis settings`)
      intatis chat            Streaming chat (no tools)
      intatis code [dir]      Coding agent: read/search/edit files, git/shell (with approval)
      intatis cowork [dir]    Multi-agent work; use /goal <objective> for durable Goal execution
      intatis settings        Interactive settings (endpoint, key, model, reasoning, mode)
      intatis config          Print the resolved config
      intatis selftest        Offline smoke test (no key)
      intatis mcp help        Manage external MCP servers and session access
      intatis exec --session <id> --agent <id> [--task <id>] --prompt <text> [--yes]
                              Run one exact durable Code/MCP turn
      intatis diagnose-hang --pid <pid> [--output <directory>]
                              Capture a 10s sample and 5m Intatis logs into an owner-only bundle
      intatis help

    CONFIG  (env var > advanced Intatis config > legacy config > default)
      INTATIS_CONFIG     optional intatis.json/jsonc using model + enabled_providers + provider map
      INTATIS_BASE_URL   default https://api.openai.com/v1
      INTATIS_API_KEY    required (any non-empty for local servers)
      INTATIS_MODEL      default gpt-4o-mini
      INTATIS_REASONING  minimal | low | medium | high
      INTATIS_MODE       chat | code | cowork

    In a session, type /help for slash commands (/model, /reasoning, /mode, /clear …).

    FIRST RUN
      intatis settings        # set endpoint + API key once
      intatis                 # then just run it — uses your saved config

    ANY VENDOR (same binary)
      INTATIS_BASE_URL=http://localhost:11434/v1 INTATIS_API_KEY=ollama INTATIS_MODEL=llama3.1 intatis chat
      INTATIS_BASE_URL=https://api.deepseek.com/v1 INTATIS_API_KEY=sk-... INTATIS_MODEL=deepseek-chat intatis chat

    """)
}
