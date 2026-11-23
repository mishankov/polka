# UI SDK for web UI

Use [UI SDK](https://github.com/vercel-labs/ui) for interactive components and
behaviors. Keep the project's visual design and the requested scope.

## Find the integration

Check the app's framework, package manager, existing components, and installed
`@ui-sdk/*` packages. Reuse existing UI SDK integration. When adding it, install
`@ui-sdk/core` and the matching adapter with the project's package manager:
`@ui-sdk/react`, `@ui-sdk/vue`, `@ui-sdk/svelte`, `@ui-sdk/solid`, or `@ui-sdk/web`.
Keep versions compatible with the app. If the framework is unsupported or a
project constraint prevents adoption, report the concrete limitation and keep
the work within the requested scope.

For a plain HTML page without a build step, follow
[the Web Components guide](https://ui-sdk.dev/web.md) for its script and stylesheet
setup instead of adding a package toolchain.

## Load the implementation guidance

Read `node_modules/@ui-sdk/core/skills/ui-sdk/SKILL.md` and follow its relevant
references. This is the SDK's own skill, matched to the installed version.
Read `node_modules/@ui-sdk/<framework>/docs/llms.txt`, then only the component
and behavior pages needed for the task. `<framework>` is `react`, `vue`, `svelte`,
`solid`, or `web`. For a page without a build step, use the Web Components guide.

If the packaged skill or docs are unavailable, consult the
[official skill](https://github.com/vercel-labs/ui/blob/main/packages/core/skills/ui-sdk/SKILL.md)
and [documentation](https://ui-sdk.dev/docs), checking compatibility with the
installed version before using an API.

Use shipped components for supported interactions. Compose core behaviors when
a required component is missing. Keep existing working components outside the
requested change intact.
