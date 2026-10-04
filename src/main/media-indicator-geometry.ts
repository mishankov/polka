import type { Notch, Rect } from './clipboard-hover';

export function mediaIndicatorGeometry(bounds: Rect, notch?: Notch) {
  const hasNotch = !!notch && notch.width > 0 && notch.height > 0;
  const notchWidth = hasNotch ? Math.round(notch.width) : 0;
  const notchHeight = hasNotch ? Math.round(notch.height) : 0;
  const width = Math.min(bounds.width, notchWidth ? notchWidth + 124 : 116);
  const height = Math.min(bounds.height, Math.max(46, notchHeight + 14));
  const center = bounds.x + (hasNotch ? notch.x + notch.width / 2 : bounds.width / 2);
  return {
    bounds: {
      x: Math.round(
        Math.max(bounds.x, Math.min(bounds.x + bounds.width - width, center - width / 2)),
      ),
      y: bounds.y,
      width,
      height,
    },
    notchWidth,
    notchHeight,
  };
}
