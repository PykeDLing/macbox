import { createFileRoute, useLocation } from '@tanstack/react-router';
import Home from '../views/Home';
import { localeOf, pathWithoutBase } from '../lib/i18n';

// 中英文首页共用这个布局路由：切换语言只是换子路由，Home 不会重新挂载，
// 演示窗口里的操作、已经淡入的版块都保留
export const Route = createFileRoute('/_home')({
  component: HomeLayout,
});

function HomeLayout() {
  const locale = useLocation({
    select: (location) => localeOf(pathWithoutBase(location.pathname, import.meta.env.BASE_URL)),
  });
  return <Home locale={locale} />;
}
