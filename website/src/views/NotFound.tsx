import { Link, useLocation } from '@tanstack/react-router';
import { homePath, localeOf, pathWithoutBase, translate } from '../lib/i18n';
import { href } from '../lib/site';

export default function NotFound() {
  const locale = useLocation({
    select: (location) => localeOf(pathWithoutBase(location.pathname, import.meta.env.BASE_URL)),
  });
  const t = translate(locale);
  return (
    <main className="not-found wrap">
      <img src={href('/icon-320.png')} width={112} height={112} alt="MacBox" />
      <p className="kicker">404</p>
      <h1>{t('这里什么也没有。', 'Nothing here.')}</h1>
      <p className="intro">{t('这个地址没有对应的页面。', 'There is no page at this address.')}</p>
      <div className="cta">
        <Link className="btn btn-primary" to={homePath(locale)}>
          {t('回到首页', 'Back to MacBox')}
        </Link>
      </div>
    </main>
  );
}
