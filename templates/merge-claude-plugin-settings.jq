.[0] as $base | .[1] as $bootstrap |
($base * $bootstrap) |
.hooks.SessionStart = (
  (($bootstrap.hooks.SessionStart // []) + ($base.hooks.SessionStart // [])) | unique
) |
.hooks.UserPromptSubmit = (
  (($bootstrap.hooks.UserPromptSubmit // []) + ($base.hooks.UserPromptSubmit // [])) | unique
) |
. as $merged |
($merged | del(.hooks, .enabledPlugins, .extraKnownMarketplaces)) + {
  hooks: $merged.hooks,
  enabledPlugins: $merged.enabledPlugins,
  extraKnownMarketplaces: $merged.extraKnownMarketplaces
}
