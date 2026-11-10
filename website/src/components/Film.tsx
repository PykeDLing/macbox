import { useEffect, useRef, useState } from 'react';
import { chapterAt, filmChapters, timestamp } from '../lib/film';
import { pick, translate, type Locale } from '../lib/i18n';
import { href } from '../lib/site';

const filmId = 'promo-film';

/** 首屏的「看 55 秒介绍」按钮用：从头播放 */
export function playFilmFromStart() {
  const video = document.getElementById(filmId);
  if (!(video instanceof HTMLVideoElement)) return;
  video.currentTime = 0;
  void video.play().catch(() => {});
}

/**
 * 宣传片和它下面的一排章节。片子没有声音：露出一大半就静音自动播放，滑走就停，
 * 自己按过暂停的不再自动播；系统设了“减弱动态效果”时不自动播
 */
export function Film({ locale }: { locale: Locale }) {
  const t = translate(locale);
  const video = useRef<HTMLVideoElement>(null);
  const [current, setCurrent] = useState(0);
  // 中英文各有一个视频文件。切换语言时接着原来的位置放，不从头再来
  const resume = useRef({ time: 0, playing: false });

  useEffect(() => {
    const el = video.current;
    if (!el) return;
    const { time, playing } = resume.current;
    if (time > 0) {
      const restore = () => {
        el.currentTime = time;
        if (playing) void el.play().catch(() => {});
      };
      if (el.readyState >= 1) restore();
      else el.addEventListener('loadedmetadata', restore, { once: true });
    }

    let pausedByViewer = false;
    let pausedByScroll = false;
    const onTime = () => {
      // 切换语言时旧的 <video> 被移出页面，之后它还会报一次时间和暂停，都不算数
      if (!el.isConnected) return;
      setCurrent(chapterAt(el.currentTime));
      resume.current = { time: el.currentTime, playing: !el.paused && !el.ended };
    };
    const onPause = () => {
      if (!el.isConnected) return;
      if (!pausedByScroll && !el.ended) pausedByViewer = true;
      pausedByScroll = false;
      resume.current.playing = false;
    };
    const onPlay = () => {
      pausedByViewer = false;
      resume.current.playing = true;
    };
    el.addEventListener('timeupdate', onTime);
    el.addEventListener('seeked', onTime);
    el.addEventListener('pause', onPause);
    el.addEventListener('play', onPlay);

    const calm = window.matchMedia?.('(prefers-reduced-motion: reduce)').matches;
    const inView =
      'IntersectionObserver' in window && !calm
        ? new IntersectionObserver(
            ([entry]) => {
              if (entry?.isIntersecting) {
                if (!pausedByViewer && !el.ended) void el.play().catch(() => {});
              } else if (!el.paused) {
                pausedByScroll = true;
                el.pause();
              }
            },
            { threshold: 0.6 },
          )
        : null;
    inView?.observe(el);

    return () => {
      inView?.disconnect();
      el.removeEventListener('timeupdate', onTime);
      el.removeEventListener('seeked', onTime);
      el.removeEventListener('pause', onPause);
      el.removeEventListener('play', onPlay);
    };
  }, [locale]);

  const jump = (start: number) => {
    const el = video.current;
    if (!el) return;
    el.currentTime = start;
    void el.play().catch(() => {});
  };

  return (
    <section className="film" id="film" aria-label={t('宣传片', 'Film')}>
      <div className="film-frame">
        <video
          // 换语言就换一个 <video>，不然旧文件的画面会留到新文件加载完
          key={locale}
          id={filmId}
          ref={video}
          src={href(`/media/macbox-promo-${locale}.mp4`)}
          poster={href(`/media/macbox-promo-${locale}-poster.jpg`)}
          width={1920}
          height={1080}
          muted
          playsInline
          preload="metadata"
          controls
        />
      </div>
      <ol className="chapters" aria-label={t('分章节观看', 'Chapters')}>
        {filmChapters.map((chapter, i) => (
          <li key={chapter.scene}>
            <button
              type="button"
              aria-current={i === current ? 'true' : undefined}
              onClick={() => jump(chapter.start)}
            >
              <span>{timestamp(chapter.start)}</span>
              {pick(locale, chapter.title)}
            </button>
          </li>
        ))}
      </ol>
      <p className="film-note">
        {t(
          '片子没有声音。点上面的章节可以直接跳过去。',
          'The film has no sound. Pick a chapter above to jump to it.',
        )}
      </p>
    </section>
  );
}
