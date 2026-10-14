import { Effect, Option, Schema } from 'effect';
import { fallbackRelease, type Release } from './release';
import { latestReleaseApi } from './site';

// GitHub API releases/latest 里用到的字段；其余字段忽略
const LatestRelease = Schema.Struct({
  tag_name: Schema.NonEmptyString,
  published_at: Schema.optional(Schema.NullOr(Schema.String)),
  assets: Schema.Array(Schema.Unknown),
});
const Dmg = Schema.Struct({
  name: Schema.String.check(Schema.isPattern(/\.dmg$/)),
  size: Schema.Finite,
  browser_download_url: Schema.String.check(Schema.isPattern(/^https:\/\//)),
  updated_at: Schema.optional(Schema.String),
});
const decodeRelease = Schema.decodeUnknownOption(LatestRelease);
const decodeDmg = Schema.decodeUnknownOption(Dmg);

export class ReleaseError extends Schema.TaggedError<ReleaseError>()('ReleaseError', {
  reason: Schema.Literals(['network', 'status', 'body']),
  cause: Schema.Defect(),
}) {}

/** 把 API 返回的 JSON 变成页面要显示的信息；格式不对时退回 fallbackRelease，单个坏掉的附件跳过 */
export function parseRelease(json: unknown): Release {
  const release = Option.getOrUndefined(decodeRelease(json));
  if (!release) return fallbackRelease;
  const dmg = release.assets.map((asset) => decodeDmg(asset)).find(Option.isSome)?.value;
  if (!dmg) return { ...fallbackRelease, version: release.tag_name };
  const published = new Date(release.published_at ?? dmg.updated_at ?? Number.NaN);
  return {
    version: release.tag_name,
    download: dmg.browser_download_url,
    dmg: Number.isNaN(published.getTime()) ? null : { size: dmg.size, published },
  };
}

/** 取最新发布。中断（组件卸载）会取消请求；超时、网络错误、状态码不对都算失败，由调用方决定退路 */
export const fetchLatestRelease = Effect.gen(function* () {
  const response = yield* Effect.tryPromise({
    try: (signal) =>
      fetch(latestReleaseApi, { signal, headers: { Accept: 'application/vnd.github+json' } }),
    catch: (cause) => new ReleaseError({ reason: 'network', cause }),
  });
  if (!response.ok) return yield* new ReleaseError({ reason: 'status', cause: response.status });
  const json = yield* Effect.tryPromise({
    try: () => response.json() as Promise<unknown>,
    catch: (cause) => new ReleaseError({ reason: 'body', cause }),
  });
  return parseRelease(json);
}).pipe(Effect.timeout('8 seconds'));
