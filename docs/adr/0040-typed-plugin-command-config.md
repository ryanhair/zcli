# Typed plugin settings on commands

Status: accepted

A plugin sometimes needs a command-specific declaration before it runs, such
as an authorization policy. A free-form metadata bag would leave field names,
defaults, and value types unchecked.

## Decision

A plugin that needs command settings declares a default-constructible
`CommandConfig` struct and a `plugin_id`. A command may override fields under
`meta.plugins.<plugin_id>`. Registry composition checks that the named plugin
is registered, that it declares `CommandConfig`, and that every supplied field
and value matches the struct. Unknown top-level command metadata remains an
error.

The routed command's settings are available in hooks as
`context.command_config.<plugin_id>`. The generated context type depends only
on the registered plugin types. The registry projects a command's metadata
into those typed fields after routing; this avoids a context-to-command import
cycle. Missing overrides use the plugin's field defaults. Alias paths share
their command module and therefore its settings. Plugin-provided commands use
the same validation and projection. Parent command settings do not implicitly
flow to child commands.

Resource acquisition remains lazy by default. A plugin's `ContextData` method
can create a daemon client on first use; commands that never call it do not
connect. `CommandConfig` is for policy that genuinely has to be known before
execution, not a substitute for acquiring a resource where it is used.

## Consequences

Plugin authors get typed settings with clear defaults and namespace ownership.
Each configured plugin requires a stable `plugin_id`. Existing commands and
plugins without `CommandConfig` require no metadata.
