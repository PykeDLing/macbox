export const repository = 'https://github.com/PykeDLing/macbox';
export const releasesPage = `${repository}/releases`;
export const latestReleasePage = `${releasesPage}/latest`;
export const latestReleaseApi = 'https://api.github.com/repos/PykeDLing/macbox/releases/latest';
export const issuesPage = `${repository}/issues`;
export const licensePage = `${repository}/blob/main/LICENSE`;
// docs/how-it-works.md 里的“限制”一节（README 只列主要的几条）
export const isolationDetails = `${repository}/blob/main/docs/how-it-works.md#${encodeURIComponent('限制')}`;
export const appVersion = `v${import.meta.env.APP_VERSION}`;

/** 站内资源地址，带上部署路径前缀 */
export const href = (path = '') =>
  `${import.meta.env.BASE_URL.replace(/\/$/, '')}/${path.replace(/^\//, '')}`;
/** 完整网址，给 canonical、og:image 这类必须写全的地方用 */
export const absoluteUrl = (path = '') =>
  new URL(path.replace(/^\//, ''), import.meta.env.SITE_URL).href;
