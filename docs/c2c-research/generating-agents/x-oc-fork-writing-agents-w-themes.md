# Writing Agents — Quick Guide

A fast reference for authoring custom agents. Covers the full frontmatter surface and how to use the new `theme` key.

## Where agents live

Two places, same schema:

- **Markdown files** (preferred for custom agents):
  - Global: `~/.config/opencode/agent/*.md` or `agents/`
  - Per-project: `.opencode/agent/*.md` or `agents/`
  - The filename (minus `.md`) is the agent name.
- **`opencode.json`** under the `agent` key, keyed by agent name.

Mode files (`mode/*.md` or `modes/*.md`) share the same schema — anything you can do for an agent you can do for a mode (including `theme`).

## Minimal agent

```markdown title=".opencode/agent/review.md"
---
description: Reviews diffs for correctness and style
mode: subagent
model: anthropic/claude-sonnet-4-20250514
---

You are a careful code reviewer. Favour concrete, line-specific
feedback over generic suggestions.
```

The body becomes the agent's system prompt.

## Frontmatter keys

| Key | Type | Purpose |
|---|---|---|
| `description` | string | Shown in menus and used by the Task tool to decide when to dispatch a subagent. |
| `mode` | `"subagent" \| "primary" \| "all"` | `primary` = user-facing, `subagent` = invoked via Task tool, `all` = either. Modes files are always `primary`. |
| `model` | `"provider/model"` | Override the default model. |
| `variant` | string | Model variant (if the model exposes variants). |
| `temperature` | number | Sampling temperature. |
| `top_p` | number | Nucleus sampling. |
| `steps` | positive int | Maximum agentic iterations before forcing a text-only response. |
| `hidden` | bool | Hide subagents from the `@` autocomplete menu. |
| `disable` | bool | Remove this agent entirely (useful to turn off a bundled one). |
| `color` | hex or palette name | Tint for the agent chip in the TUI (e.g. `#FF5733` or `primary`, `accent`, `success`, ...). |
| `theme` | name / inline / `{light,dark}` | **New.** Overlay a full theme while this agent is active. See below. |
| `permission` | object | Per-tool permission rules. |
| `prompt` | string | Inline system prompt (otherwise the markdown body is used). |

Anything else goes through to the provider as model options (e.g. `reasoningEffort: "high"`).

## The `theme` key

Applies a theme overlay while the agent is active. When you switch to a different agent without a `theme`, the overlay clears and your configured theme resurfaces. Nothing is written to disk.

### Three shapes

**1. Theme name** — any bundled or custom theme.

```yaml
---
description: Neon, baby
theme: synthwave84
---
```

**2. Inline theme** — the same `ThemeJson` shape you'd put in a `themes/*.json` file. `defs` is an optional alias map; `theme` holds the colour values.

```yaml
---
description: High-contrast audit mode
theme:
  defs:
    bg: "#0a0a0a"
    accent: "#ff3366"
  theme:
    background: bg
    text: "#ffffff"
    primary: accent
    border: "#222222"
    # ... any other ThemeColor keys you want to override
---
```

Keys that aren't overridden fall back to sensible defaults (e.g. `selectedListItemText` defaults to `background`, `backgroundMenu` defaults to `backgroundElement`).

**3. Variant pair** — `{ light, dark }`. Each side is a name or an inline theme. The TUI picks the side that matches the current light/dark mode, and re-picks live if you toggle mode mid-session.

```yaml
---
description: Looks right in either mode
theme:
  light: github
  dark: tokyonight
---
```

Or mix the shapes:

```yaml
---
theme:
  light: github
  dark:
    theme:
      background: "#000000"
      text: "#ffffff"
      primary: "#00ffaa"
---
```

### Where it works

- **TUI:** yes. Overlay applies on agent activation, clears on switch-away.
- **Web / desktop client:** not yet — follow-up patch.
- **Subagents:** no. Subagent dispatch doesn't retint; the overlay is tied to the primary/all agent you're actively talking to.

### Failure modes

- Unknown theme name → warning toast, overlay does not apply, your base theme is unchanged.
- Inline theme with unresolvable colour references → warning toast, overlay cleared, base theme returns.

The agent itself still loads and is usable; only the theme is dropped.

## Handy patterns

**Plan mode gets a distinct look:**

```markdown title=".opencode/mode/plan.md"
---
description: Planning mode — no edits
theme: kanagawa
---

You are in planning mode...
```

**Design-review agent that's legible on light and dark terminals:**

```markdown title=".opencode/agent/design-review.md"
---
description: Reviews visual design changes
mode: primary
theme:
  light: solarized
  dark: rosepine
---

Focus on visual hierarchy, contrast, and spacing...
```

**Security-review agent with a bespoke high-alert palette:**

```markdown title=".opencode/agent/security.md"
---
description: Red-team style security audit
mode: primary
color: error
theme:
  defs:
    alert: "#ff2244"
  theme:
    background: "#100808"
    text: "#ffdddd"
    primary: alert
    accent: alert
    border: "#552222"
---

You are a security reviewer...
```

## See also

- `packages/web/src/content/docs/agents.mdx` — the full agents reference.
- `packages/opencode/src/cli/cmd/tui/context/theme/*.json` — shape reference for inline themes (copy one and trim the keys you don't need).
