import { useEffect, useState, type CSSProperties } from 'react';
import { createRoot } from 'react-dom/client';
import { IconVideo, IconMicrophone, IconQuestionMark } from '@tabler/icons-react';
import { mediaActivityLabel, type MediaIndicatorPresentation } from '../../shared/media-indicator';
import './media-indicator.css';

function Indicator() {
  const [state, setState] = useState<MediaIndicatorPresentation>();
  useEffect(() => {
    let received = false;
    let alive = true;
    const unsubscribe = window.mediaIndicator.onChange((value) => {
      received = true;
      setState(value);
    });
    void window.mediaIndicator
      .getState()
      .then((value) => {
        if (alive && !received) setState(value);
      })
      .catch(console.error);
    return () => {
      alive = false;
      unsubscribe();
    };
  }, []);
  if (!state) return null;
  const { camera, microphone, notchWidth, notchHeight } = state;
  const mode =
    camera === 'active' && microphone === 'active'
      ? 'both'
      : camera === 'active'
        ? 'camera'
        : microphone === 'active'
          ? 'microphone'
          : 'unknown';
  const unknown = camera === 'unknown' || microphone === 'unknown';
  return (
    <div
      className="media-indicator"
      data-mode={mode}
      data-notched={notchWidth > 0 || undefined}
      data-unknown={unknown || undefined}
      role="status"
      aria-label={mediaActivityLabel(state)}
      style={
        {
          '--notch-width': `${notchWidth}px`,
          '--notch-height': `${notchHeight}px`,
        } as CSSProperties
      }
    >
      <div className="media-rim" />
      {(camera === 'active' || camera === 'unknown') && (
        <span className="media-device media-camera" data-state={camera}>
          <IconVideo size={25} stroke={2.2} />
          {camera === 'unknown' && <IconQuestionMark className="media-question" size={13} />}
        </span>
      )}
      {(microphone === 'active' || microphone === 'unknown') && (
        <span className="media-device media-microphone" data-state={microphone}>
          <IconMicrophone size={25} stroke={2.2} />
          {microphone === 'unknown' && <IconQuestionMark className="media-question" size={13} />}
        </span>
      )}
    </div>
  );
}
createRoot(document.getElementById('root')!).render(<Indicator />);
