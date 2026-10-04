export interface Rect {
  x: number;
  y: number;
  width: number;
  height: number;
}
export interface Notch {
  id: number;
  x: number;
  width: number;
  height: number;
}
export function contains(rect: Rect, point: { x: number; y: number }) {
  return (
    point.x >= rect.x &&
    point.x < rect.x + rect.width &&
    point.y >= rect.y &&
    point.y < rect.y + rect.height
  );
}
export function shelfGeometry(bounds: Rect, notch?: Notch, expanded: boolean | 'settings' = false) {
  const hasNotch = notch && notch.height > 0 && notch.width > 0;
  const target = hasNotch
    ? { x: bounds.x + notch.x, y: bounds.y, width: notch.width, height: notch.height }
    : { x: bounds.x + (bounds.width - 96) / 2, y: bounds.y, width: 96, height: 3 };
  const width = Math.min(expanded === 'settings' ? 720 : expanded ? 960 : 560, bounds.width);
  const topInset = hasNotch ? Math.ceil(notch.height) : 0;
  const panel = {
    x: Math.round(
      Math.max(
        bounds.x,
        Math.min(bounds.x + bounds.width - width, target.x + target.width / 2 - width / 2),
      ),
    ),
    y: bounds.y,
    width,
    height: Math.min((expanded ? 680 : 510) + topInset, bounds.height),
  };
  const corridor = { ...panel };
  return { target, panel, corridor, topInset };
}
// Explicit dismissal requires leaving the hot zone before another hover can reopen it.
export class ClipboardHover {
  private enteredAt: number | undefined;
  private leftAt: number | undefined;
  private suppressed = false;
  dismiss() {
    this.suppressed = true;
    this.enteredAt = undefined;
    this.leftAt = undefined;
  }
  step(
    now: number,
    inTarget: boolean,
    inCorridor: boolean,
    visible: boolean,
  ): 'show' | 'hide' | undefined {
    if (!inTarget) {
      this.suppressed = false;
      this.enteredAt = undefined;
    }
    if (visible) {
      this.enteredAt = undefined;
      if (inCorridor) this.leftAt = undefined;
      else {
        this.leftAt ??= now;
        if (now - this.leftAt >= 150) {
          this.leftAt = undefined;
          return 'hide';
        }
      }
    } else {
      this.leftAt = undefined;
      if (inTarget && !this.suppressed) {
        this.enteredAt ??= now;
        if (now - this.enteredAt >= 350) {
          this.enteredAt = undefined;
          return 'show';
        }
      }
    }
  }
}
