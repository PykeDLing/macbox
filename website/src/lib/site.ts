export const repository = 'https://github.com/PykeDLing/macbox';
export const releasesPage = `${repository}/releases`;
export const latestReleasePage = `${releasesPage}/latest`;
export const latestReleaseApi = 'https://api.github.com/repos/PykeDLing/macbox/releases/latest';
export const issuesPage = `${repository}/issues`;
export const licensePage = `${repository}/blob/main/LICENSE`;
// README 里“本机隔离是怎么做到的”一节
export const isolationDetails = `${repository}#${encodeURIComponent('本机隔离是怎么做到的')}`;
export const appVersion = `v${import.meta.env.APP_VERSION}`;

/** 站内资源地址，带上部署路径前缀 */
export const href = (path = '') =>
  `${import.meta.env.BASE_URL.replace(/\/$/, '')}/${path.replace(/^\//, '')}`;
/** 完整网址，给 canonical、og:image 这类必须写全的地方用 */
export const absoluteUrl = (path = '') =>
  new URL(path.replace(/^\//, ''), import.meta.env.SITE_URL).href;
