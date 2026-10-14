/// <reference types="vite/client" />

interface ImportMetaEnv {
  /** Resources/Info.plist 里的 App 版本号 */
  readonly APP_VERSION: string;
  /** 网站根目录的完整网址，以 / 结尾 */
  readonly SITE_URL: string;
}
