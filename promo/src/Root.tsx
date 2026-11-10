import { Composition } from 'remotion';
import { Promo } from './Promo';
import { FPS, H, TOTAL_FRAMES, W } from './theme';

export const Root = () => (
  <>
    <Composition
      id="Promo-zh"
      component={Promo}
      durationInFrames={TOTAL_FRAMES}
      fps={FPS}
      width={W}
      height={H}
      defaultProps={{ lang: 'zh' as const }}
    />
    <Composition
      id="Promo-en"
      component={Promo}
      durationInFrames={TOTAL_FRAMES}
      fps={FPS}
      width={W}
      height={H}
      defaultProps={{ lang: 'en' as const }}
    />
  </>
);
