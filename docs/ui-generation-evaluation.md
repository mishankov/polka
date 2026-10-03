# UI generation evaluation

Use a disposable profile with an explicitly configured provider. Run each prompt in a fresh conversation, record the model and app version, and retain the generated definition and observed failures. Compare the same scenarios before and after guidance changes. Do not use personal records or count protocol mocks as model-quality evidence.

| Scenario and prompt | Observable success criteria |
| --- | --- |
| «Создай приложение, чтобы быстро добавлять расходы с названием и суммой и видеть список расходов.» | Main task is available immediately; fields have labels; valid amounts follow the intended domain; invalid input gets a useful explanation; repeated submission does not create duplicate records while a save is pending; failed saves preserve input; success is visible and the list updates. |
| «Создай доску задач с этапами Планы, В работе и Готово.» | Uses the built-in board when sufficient; new tasks have a sensible initial stage; tasks can be created, moved and edited; no unsolicited dashboard or unrelated required fields; empty stages and long titles remain usable. |
| «Создай маленький индикатор активности камеры и микрофона для отдельного окна.» | Follows platform capability guidance; distinguishes active, inactive, unknown and denied access; status has a text equivalent; explains how the user grants access and opens the window; polling cleans up; the screen fits a narrow window without extra navigation. |

For each generated app, complete the main task with keyboard and pointer. Inspect supported light/dark themes and narrow/wide windows. Try zero, one and more records than a single page, long text, a recoverable read failure and a recoverable write failure. Verify data persists after reopening. Record unsupported or untested states explicitly.

Score each applicable criterion as pass, fail, or untested, with evidence. Blocked main tasks, lost input, duplicate writes, inaccessible actions, and false success reports are failures regardless of appearance. Fix a recurring issue in the shared component when it is platform-owned; improve agent guidance when the model chose or implemented the interaction incorrectly.

Automated delivery and compilation checks: `npx tsx --test tests/platform-capabilities.test.ts`. These establish valid examples and runtime delivery, not adherence by a live model or usability of arbitrary generated screens.
