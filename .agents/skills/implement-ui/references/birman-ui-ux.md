# UI/UX with Ilya Birman's guidance

Apply the principles below to the user's actual product and requested scope. This is an independent synthesis of Birman's public writing, not an official skill or an instruction to imitate his personality or visual style. Preserve the product's established design language unless changing it is part of the task.

Source numbers refer to [source notes](birman-sources.md). Read the relevant entries when explaining a recommendation, resolving an apparent exception, or attributing a rule. The operational workflow below is a synthesis; do not present it as Birman's own checklist. His explanations of established concepts such as Fitts's law do not imply he invented them.

## Understand the task before arranging controls

Describe the user's real situation: what they need to achieve, what information they have, and what constraints they face. Use the vocabulary of their domain. A manager identifying projects that need intervention is a scenario; opening a dashboard is an interface step. Keep scenarios distinct from screen transitions and implementation specifications. For a small edit, infer this context from the existing task rather than requiring a separate discovery exercise. [1]

Check whether navigation exposes useful destinations directly. An account hub or registration step can become an unnecessary prerequisite; consider identifying the person when the chosen action actually requires it. Preserve genuine access requirements. [2]

## Give controls and text a coherent meaning

- Treat a form as a readable construction: its heading identifies the subject, its fields specify details, and its command button states the action. Remove redundant wording while retaining clarity when the heading and button are far apart. Prefer specific objects over generic labels. [3]
- Match button text to function. Commands usually use verbs, navigation may name a destination, and status assignment can use a status phrase. Do not force every button into an imperative label. Make buttons recognizable and provide a perceptible response when the outcome is delayed. [4]
- Use a checkbox when the unchecked meaning is obvious. Otherwise expose named alternatives, such as portrait and landscape. Prefer positive labels and meaningful defaults; avoid ambiguous labels such as “Yes” and confusing negations. Keep grouped choices grammatically compatible with their shared label. Make the label clickable. [5]
- Disabled controls can preserve location and communicate temporary unavailability. Do not ban them categorically. When users cannot infer what is missing, provide an understandable route forward; for example, a purchase action can guide them to an omitted date field. An accessible button does not justify accepting an impossible order or changing user selections silently. The rental example depended on a specific operational fallback. [6, 7]

## Arrange the interface for reading and action

- Keep labels visibly associated with their fields. Choose field dimensions, grouping, and the position of the final action together. Do not turn a comparison that changes several variables into a universal rule that labels must always sit above fields. [8]
- Make targets large and close enough for practical pointing. Separate actions that would be harmful to confuse. Increasing an already large button provides diminishing benefit; do not invent a universal pixel threshold and attribute it to Birman. [9]
- On wider screens, evaluate whether a vertical stack wastes usable space and causes unnecessary scrolling. Use the available width when it improves relationships or access. A stack remains appropriate for narrow screens and many sidebars; multiple columns are not inherently better. [10]
- Question modes introduced merely to hide controls. Distinguish mode-dependent input behavior from blocking modal dialogs. Consider separate gestures, temporary held modes, or a changed interaction sequence where appropriate. If a mode remains necessary, make it evident. Assess a modal dialog by the choice it requires and its effect on the user's task. [11]

## Check completeness of states and transitions

For the affected interface, answer:

- What does each available action do, and what state follows?
- After closing or hiding something, how can the user return to it?
- What happens with zero items, one item, or many more items than the mockup shows?
- What happens with short, long, zero, negative, or extreme values, where those values are valid in the domain?
- What happens when values or item counts change while the interface is open? [12]

As an implementation extension of these checks, cover relevant loading, failure, retry, and success behavior. Preserve entered work where the task requires it. Investigate contradictory outcomes or unreachable states rather than adding ad hoc exceptions. Scale the verification to the change; a full state diagram is not required for every edit.

## Build reusable components from demonstrated needs

Start with existing components that have proved useful. Check their behavior with long text, small screens, and supported themes. Reuse actual implementations, not copied markup that only looks consistent. Extend the library alongside product work instead of making a complete design system a prerequisite. [13]

## Deliver a concrete result

For implementation work, make the authorized changes and verify the affected behavior and layout using available project tools. For a review, identify concrete problems, their effect on the user's task, and a proposed correction. Prioritize blocked tasks, ambiguous actions, and missing behavior before cosmetic adjustments.

Explain the important decisions briefly. Distinguish observed problems from assumptions and untested states. Cite the relevant source when attributing advice to Birman. Treat established accessibility requirements and platform constraints as additional inputs; this collection is not a complete accessibility standard.
